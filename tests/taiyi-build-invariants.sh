#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Helpers copied verbatim into the target must retain a usable Unix shebang.
firmware_helpers=(
    990_set_argon_primary
    991_custom_settings
    993_disable_unpublished_distfeeds
    995_configure_taiyi_apk_repositories
    cpuusage
    hnatusage
    smp_affinity
    tempinfo
    pbr.user.cmcc
    pbr.user.cmcc6
)
for helper in "${firmware_helpers[@]}"; do
    helper_path="$repo_root/wrt_core/patches/$helper"
    [[ -f $helper_path ]] || fail "missing firmware helper: $helper"
    if LC_ALL=C grep -q $'\r' "$helper_path"; then
        fail "firmware helper contains CR bytes: $helper"
    fi
done

# ER1 selects the OpenWrt 25.12 package manager after the shared opkg default.
apk_fragment="$repo_root/wrt_core/deconfig/fragments/apk.config"
for symbol in \
    CONFIG_USE_APK \
    CONFIG_SIGNED_PACKAGES \
    CONFIG_DOWNLOAD_CHECK_CERTIFICATE \
    CONFIG_PACKAGE_apk-openssl \
    CONFIG_PACKAGE_luci-app-package-manager \
    CONFIG_PACKAGE_openwrt-keyring; do
    grep -qFx "$symbol=y" "$apk_fragment" \
        || fail "APK fragment does not enable $symbol"
done
grep -qFx '# CONFIG_PACKAGE_opkg is not set' "$apk_fragment" \
    || fail 'APK fragment does not disable opkg'
grep -qFx '# CONFIG_PACKAGE_luci-lib-ipkg is not set' "$apk_fragment" \
    || fail 'APK fragment retains the legacy LuCI ipkg library'
grep -qF 'ApkBuildPublicKeySha256:' "$repo_root/build.sh" \
    || fail 'build provenance omits the APK build public-key fingerprint'
grep -qF 'etc/apk/keys/public-key.pem' "$repo_root/wrt_core/modules/profile_verify.sh" \
    || fail 'rootfs policy does not require the APK build public key'
grep -qF 'APK private key leaked into the packaged rootfs' \
    "$repo_root/wrt_core/modules/profile_verify.sh" \
    || fail 'rootfs policy does not reject APK private-key leakage'
grep -Eq '^CONFIG_FRAGMENTS=([^,]+,)*apk(,[^,]+)*$' \
    "$repo_root/wrt_core/compilecfg/jdcloud_er1_libwrt.ini" \
    || fail 'ER1 profile does not include the APK fragment'

# Production publication must reject native or unreviewed builder provenance.
release_workflow="$repo_root/.github/workflows/release_wrt.yml"
grep -qF "expected_container_base='ubuntu:24.04@sha256:a61567bd31828687156d735ea8eb01ba4e37636e225dd6a48ba94136a70d9d61'" \
    "$release_workflow" \
    || fail 'release workflow does not pin the audited builder base digest'
grep -qF "expected_container_id='sha256:671e57ed9daef17d6a23cd0315d04ed287e3307baf3004f031578069021da98b'" \
    "$release_workflow" \
    || fail 'release workflow does not pin the audited builder image ID'
grep -qF 'grep -qFx "WrtReleaseTreeState: clean" firmware/BUILD_PROVENANCE.txt' \
    "$release_workflow" \
    || fail 'release workflow can publish a dirty-tree build'
grep -qF 'grep -qFx "BuildContainerImageId: $expected_container_id" firmware/BUILD_PROVENANCE.txt' \
    "$release_workflow" \
    || fail 'release workflow does not enforce the audited builder image ID'

apk_repo_policy="$repo_root/wrt_core/patches/995_configure_taiyi_apk_repositories"
if grep -Eq '/targets/|/kmods/' "$apk_repo_policy"; then
    fail 'ER1 APK policy must not enable public target or kmod repositories'
fi
if grep -Eq -- '--allow-untrusted|allow_untrusted|check_signature.*(0|off|no)' "$apk_repo_policy"; then
    fail 'ER1 APK policy weakens package signature verification'
fi

# ER1 source preparation installs the APK policy and omits unsafe generic defaults.
mkdir -p "$tmp/er1-build/package/base-files/files/etc/uci-defaults"
BASE_PATH="$repo_root/wrt_core"
BUILD_DIR="$tmp/er1-build"
THEME_SET=argon
source "$repo_root/wrt_core/modules/target_fixes.sh"
is_er1_profile() { return 0; }
fix_default_set
cmp -s "$apk_repo_policy" \
    "$BUILD_DIR/package/base-files/files/etc/uci-defaults/995_configure_taiyi_apk_repositories" \
    || fail 'ER1 APK repository policy was not installed'
[[ ! -e $BUILD_DIR/package/base-files/files/etc/uci-defaults/993_disable_unpublished_distfeeds ]] \
    || fail 'ER1 retained the obsolete opkg distfeeds guard'
[[ ! -e $BUILD_DIR/package/base-files/files/etc/uci-defaults/991_custom_settings ]] \
    || fail 'ER1 must not remove the Dropbear interface restriction'
[[ ! -e $BUILD_DIR/package/base-files/files/etc/uci-defaults/992_set-wifi-uci.sh ]] \
    || fail 'ER1 Wi-Fi defaults must remain absent'

# The APK policy exposes only signed architecture feeds, removes retained opkg
# state, and preserves administrator-owned APK custom feeds.
mkdir -p "$tmp/apk-repositories" "$tmp/legacy-opkg" "$tmp/legacy-opkg-lists"
printf '%s\n' 'https://packages.example.invalid/taiyi/packages.adb' \
    >"$tmp/apk-repositories/customfeeds.list"
printf 'legacy\n' >"$tmp/legacy-opkg/distfeeds.conf"
printf 'legacy\n' >"$tmp/legacy-opkg.conf"
printf 'legacy\n' >"$tmp/legacy-opkg-lists/index"
custom_feed_before=$(sha256sum "$tmp/apk-repositories/customfeeds.list")
APK_REPOSITORIES_DIR="$tmp/apk-repositories" \
LEGACY_OPKG_DIR="$tmp/legacy-opkg" \
LEGACY_OPKG_CONF="$tmp/legacy-opkg.conf" \
LEGACY_OPKG_LISTS_DIR="$tmp/legacy-opkg-lists" \
    sh "$apk_repo_policy"
[[ ! -e $tmp/legacy-opkg && ! -e $tmp/legacy-opkg.conf \
    && ! -e $tmp/legacy-opkg-lists ]] \
    || fail 'retained opkg state was not removed'
[[ $(sha256sum "$tmp/apk-repositories/customfeeds.list") == "$custom_feed_before" ]] \
    || fail 'administrator APK custom feeds were overwritten'
cat >"$tmp/expected-distfeeds.list" <<'EOF'
# Taiyi user-space feeds. Public target and kmods feeds are intentionally omitted.
https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_cortex-a53/base/packages.adb
https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_cortex-a53/luci/packages.adb
https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_cortex-a53/packages/packages.adb
https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_cortex-a53/routing/packages.adb
https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_cortex-a53/telephony/packages.adb
EOF
cmp -s "$tmp/expected-distfeeds.list" "$tmp/apk-repositories/distfeeds.list" \
    || fail 'ER1 APK architecture repository set differs from the approved policy'
[[ $(grep -c '^https://' "$tmp/apk-repositories/distfeeds.list") -eq 5 ]] \
    || fail 'ER1 APK policy must enable exactly five architecture repositories'
if grep -Eq '/targets/|/kmods/' "$tmp/apk-repositories/distfeeds.list"; then
    fail 'ER1 APK runtime policy enabled a public target or kmod repository'
fi

# No profile may recreate the historical unsigned 24.10-SNAPSHOT fallback.
service_fixes="$repo_root/wrt_core/modules/service_fixes.sh"
if grep -qF '24.10-SNAPSHOT' "$service_fixes"; then
    fail 'unsafe 24.10-SNAPSHOT opkg fallback remains reachable'
fi
if grep -Eq 'sed.*check_signature|check_signature.*(0|off|no)' "$service_fixes"; then
    fail 'service fixes can weaken package signature verification'
fi

# The ER1 LuCI backend must reject broad APK upgrades.
package_manager_dir="$tmp/package-manager-build/package/feeds/luci/luci-app-package-manager"
mkdir -p "$package_manager_dir/root/usr/libexec"
cat >"$package_manager_dir/root/usr/libexec/package-manager-call" <<'EOF'
#!/bin/sh

. /usr/share/libubox/jshn.sh

action=$1
shift

if [ -f /usr/bin/apk ]; then
	ipkg_bin="apk"
else
	ipkg_bin="opkg"
fi

case "$action" in
	list-installed)
		if [ $ipkg_bin = "apk" ]; then
			:
		else
			:
		fi
	;;
esac
EOF
BASE_PATH="$repo_root/wrt_core"
BUILD_DIR="$tmp/package-manager-build"
source "$service_fixes"
restrict_er1_luci_apk_upgrade
package_manager_call="$package_manager_dir/root/usr/libexec/package-manager-call"
grep -qF 'Full APK upgrades are disabled on Taiyi' "$package_manager_call" \
    || fail 'Taiyi LuCI package manager does not reject broad APK upgrades'

# A pinned checkout leaves HEAD detached. The next reset must safely reattach
# to the configured branch before detaching at the pin again.
git init -q --bare "$tmp/remote.git"
git init -q "$tmp/seed"
git -C "$tmp/seed" config user.name test
git -C "$tmp/seed" config user.email test@example.invalid
printf 'one\n' >"$tmp/seed/file"
git -C "$tmp/seed" add file
git -C "$tmp/seed" commit -qm one
git -C "$tmp/seed" branch -M stable
git -C "$tmp/seed" remote add origin "$tmp/remote.git"
git -C "$tmp/seed" push -q -u origin stable
pinned_commit=$(git -C "$tmp/seed" rev-parse HEAD)
git clone -q -b stable "$tmp/remote.git" "$tmp/checkout"
git -C "$tmp/checkout" checkout -q --detach "$pinned_commit"
(
    source "$repo_root/wrt_core/modules/network.sh"
    source "$repo_root/wrt_core/modules/repo.sh"
    cd "$tmp/checkout"
    REPO_BRANCH=stable
    COMMIT_HASH=$pinned_commit
    reset_feeds_conf
    [[ $(git rev-parse HEAD) == "$pinned_commit" ]]
    [[ $(git symbolic-ref -q HEAD || true) == "" ]]
)

# Feed pinning must replace floating entries and produce one exact source line.
source "$repo_root/wrt_core/source-locks.env"
commit_lock_count=$(grep -c '_COMMIT="[0-9a-f]\{40\}"$' "$repo_root/wrt_core/source-locks.env")
[[ $commit_lock_count -eq 15 ]] || fail "expected 15 Git commit locks, got $commit_lock_count"
[[ $GEOIP_LOCKED_VERSION =~ ^[0-9]{12}$ ]]
[[ $GEOIP_SOURCE_SHA256 =~ ^[0-9a-f]{64}$ ]]
[[ $GEOIP_CN_PRIVATE_SHA256 =~ ^[0-9a-f]{64}$ ]]
source "$repo_root/wrt_core/modules/feeds.sh"
printf '%s\n' \
    'src-git nss_packages https://github.com/qosmio/nss-packages.git' \
    'src-git openwrt_bandix https://github.com/timsaya/openwrt-bandix.git;main' \
    >"$tmp/feeds.conf"
set_pinned_feed "$tmp/feeds.conf" nss_packages https://github.com/qosmio/nss-packages.git "$NSS_PACKAGES_FEED_COMMIT"
set_pinned_feed "$tmp/feeds.conf" openwrt_bandix https://github.com/timsaya/openwrt-bandix.git "$OPENWRT_BANDIX_FEED_COMMIT"
[[ $(grep -c '^src-git nss_packages ' "$tmp/feeds.conf") -eq 1 ]]
grep -qFx "src-git nss_packages https://github.com/qosmio/nss-packages.git^$NSS_PACKAGES_FEED_COMMIT" "$tmp/feeds.conf"
grep -qFx "src-git openwrt_bandix https://github.com/timsaya/openwrt-bandix.git^$OPENWRT_BANDIX_FEED_COMMIT" "$tmp/feeds.conf"

# GeoIP replacement is derived only from locked version/hash values.
mkdir -p "$tmp/custom-packages/v2ray-geodata"
cat >"$tmp/custom-packages/v2ray-geodata/Makefile" <<EOF
GEOIP_VER:=$GEOIP_LOCKED_VERSION
GEOIP_FILE:=geoip.dat.\$(GEOIP_VER)
URL_FILE:=geoip.dat
HASH:=$GEOIP_SOURCE_SHA256
EOF
get_custom_feed_package_dir() { printf '%s\n' "$tmp/custom-packages"; }
source "$repo_root/wrt_core/modules/service_fixes.sh"
update_geoip
grep -qF 'GEOIP_FILE:=geoip-only-cn-private.dat.$(GEOIP_VER)' "$tmp/custom-packages/v2ray-geodata/Makefile"
grep -qF "HASH:=$GEOIP_CN_PRIVATE_SHA256" "$tmp/custom-packages/v2ray-geodata/Makefile"

# PBR include helpers are shell executables; APK preserves the Makefile mode.
pbr_root="$tmp/pbr-executable-helpers"
mkdir -p \
    "$pbr_root/package/feeds/packages/pbr/files/usr/share/pbr" \
    "$pbr_root/package/feeds/packages/pbr/files/etc/config"
printf '%s\n' \
    'define Package/pbr/install' \
    $'\t$(INSTALL_DATA) ./files/usr/share/pbr/pbr.user.netflix $(1)/usr/share/pbr/pbr.user.netflix' \
    'endef' \
    >"$pbr_root/package/feeds/packages/pbr/Makefile"
printf '%s\n' \
    'config include' \
    "\toption path '/usr/share/pbr/pbr.user.netflix'" \
    "\toption enabled '0'" \
    >"$pbr_root/package/feeds/packages/pbr/files/etc/config/pbr"
BUILD_DIR="$pbr_root"
BASE_PATH="$repo_root/wrt_core"
install_pbr_cmcc
for pbr_helper in pbr.user.cmcc pbr.user.cmcc6; do
    [[ $(stat -c '%a' "$pbr_root/package/feeds/packages/pbr/files/usr/share/pbr/$pbr_helper") == 755 ]] \
        || fail "$pbr_helper source is not executable"
    grep -qFx $'\t$(INSTALL_BIN) ./files/usr/share/pbr/'"$pbr_helper"$' $(1)/usr/share/pbr/'"$pbr_helper" \
        "$pbr_root/package/feeds/packages/pbr/Makefile" \
        || fail "$pbr_helper is not packaged with INSTALL_BIN"
done
pbr_hash_before=$(sha256sum \
    "$pbr_root/package/feeds/packages/pbr/Makefile" \
    "$pbr_root/package/feeds/packages/pbr/files/etc/config/pbr")
install_pbr_cmcc
[[ $(sha256sum \
    "$pbr_root/package/feeds/packages/pbr/Makefile" \
    "$pbr_root/package/feeds/packages/pbr/files/etc/config/pbr") == "$pbr_hash_before" ]] \
    || fail 'PBR executable helper installation is not idempotent'

# ER1 APK package versions must omit the upstream LuCI leading "v" while
# leaving unrelated target packages and their source-version semantics alone.
source "$repo_root/wrt_core/modules/feed_source_fixes.sh"
luci_docker_root="$tmp/luci-docker-apk-versions"
mkdir -p \
    "$luci_docker_root/feeds/luci/libs/luci-lib-docker" \
    "$luci_docker_root/feeds/luci/applications/luci-app-dockerman"
printf 'PKG_VERSION:=v0.3.4\n' \
    >"$luci_docker_root/feeds/luci/libs/luci-lib-docker/Makefile"
printf 'PKG_VERSION:=v0.5.26\n' \
    >"$luci_docker_root/feeds/luci/applications/luci-app-dockerman/Makefile"
BUILD_DIR="$luci_docker_root"
fix_luci_docker_apk_versions
grep -qFx 'PKG_VERSION:=0.3.4' \
    "$luci_docker_root/feeds/luci/libs/luci-lib-docker/Makefile" \
    || fail 'luci-lib-docker retained an APK-invalid leading v'
grep -qFx 'PKG_VERSION:=0.5.26' \
    "$luci_docker_root/feeds/luci/applications/luci-app-dockerman/Makefile" \
    || fail 'luci-app-dockerman retained an APK-invalid leading v'
luci_docker_hash_before=$(sha256sum \
    "$luci_docker_root/feeds/luci/libs/luci-lib-docker/Makefile" \
    "$luci_docker_root/feeds/luci/applications/luci-app-dockerman/Makefile")
fix_luci_docker_apk_versions
[[ $(sha256sum \
    "$luci_docker_root/feeds/luci/libs/luci-lib-docker/Makefile" \
    "$luci_docker_root/feeds/luci/applications/luci-app-dockerman/Makefile") \
    == "$luci_docker_hash_before" ]] \
    || fail 'LuCI Docker APK version normalization is not idempotent'
call_count=$(grep -c '^[[:space:]]*fix_luci_docker_apk_versions[[:space:]]*$' \
    "$repo_root/wrt_core/update.sh")
[[ $call_count -eq 1 ]] \
    || fail "expected one LuCI Docker APK version normalization call, got $call_count"
awk '
    function trimmed(value) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return value
    }
    /^stage_pre_install_source_fixes\(\) \{$/ { in_stage = 1; next }
    in_stage && /^}$/ { in_stage = 0 }
    in_stage && trimmed($0) == "update_dockerman" {
        if ((getline condition) <= 0 || (getline call) <= 0 || (getline closing_line) <= 0)
            exit 1
        if (trimmed(condition) == "if is_er1_profile; then" &&
            trimmed(call) == "fix_luci_docker_apk_versions" &&
            trimmed(closing_line) == "fi")
            found = 1
    }
    END { exit(found ? 0 : 1) }
' "$repo_root/wrt_core/update.sh" \
    || fail 'LuCI Docker APK normalization is not ER1-only immediately after update_dockerman'
rm -f "$luci_docker_root/feeds/luci/applications/luci-app-dockerman/Makefile"
if fix_luci_docker_apk_versions >/dev/null 2>&1; then
    fail 'LuCI Docker APK version normalization accepted a missing required Makefile'
fi
printf 'PKG_VERSION:=0.5.26\n' \
    >"$luci_docker_root/feeds/luci/applications/luci-app-dockerman/Makefile"
printf 'PKG_VERSION:=0bad&/\n' \
    >"$luci_docker_root/feeds/luci/libs/luci-lib-docker/Makefile"
if fix_luci_docker_apk_versions >/dev/null 2>&1; then
    fail 'LuCI Docker APK version normalization accepted a malformed numeric-leading version'
fi
printf 'PKG_VERSION:=v0.3.4\nPKG_VERSION:=v0.3.4\n' \
    >"$luci_docker_root/feeds/luci/libs/luci-lib-docker/Makefile"
if fix_luci_docker_apk_versions >/dev/null 2>&1; then
    fail 'LuCI Docker APK version normalization accepted duplicate declarations'
fi
printf 'PKG_VERSION:=v0.3.4\r\n' \
    >"$luci_docker_root/feeds/luci/libs/luci-lib-docker/Makefile"
if fix_luci_docker_apk_versions >/dev/null 2>&1; then
    fail 'LuCI Docker APK version normalization accepted a CR-terminated version'
fi

# APK package ownership must keep both OAF ACL documents under unique paths.
oaf_root="$tmp/oaf-apk-acl"
mkdir -p \
    "$oaf_root/open-app-filter/files" \
    "$oaf_root/luci-app-oaf/root/usr/share/rpcd/acl.d"
printf '%s\n' 'backend acl' >"$oaf_root/open-app-filter/files/luci-app-oaf.json"
printf '%s\n' 'frontend acl' \
    >"$oaf_root/luci-app-oaf/root/usr/share/rpcd/acl.d/luci-app-oaf.json"
printf '%s\n' \
    'define Package/appfilter/install' \
    $'\t$(INSTALL_DATA) ./files/luci-app-oaf.json $(1)/usr/share/rpcd/acl.d/' \
    'endef' \
    >"$oaf_root/open-app-filter/Makefile"
get_custom_feed_worktree_dir() { printf '%s\n' "$oaf_root"; }
fix_oaf_apk_acl_collision
grep -qFx $'\t$(INSTALL_DATA) ./files/luci-app-oaf.json $(1)/usr/share/rpcd/acl.d/appfilter.json' \
    "$oaf_root/open-app-filter/Makefile" \
    || fail 'OAF backend ACL did not receive a unique APK package path'
oaf_makefile_hash_before=$(sha256sum "$oaf_root/open-app-filter/Makefile")
fix_oaf_apk_acl_collision
[[ $(sha256sum "$oaf_root/open-app-filter/Makefile") == "$oaf_makefile_hash_before" ]] \
    || fail 'OAF APK ACL collision fix is not idempotent'
oaf_call_count=$(grep -c '^[[:space:]]*fix_oaf_apk_acl_collision[[:space:]]*$' \
    "$repo_root/wrt_core/update.sh")
[[ $oaf_call_count -eq 1 ]] \
    || fail "expected one OAF APK ACL collision fix call, got $oaf_call_count"
awk '
    function trimmed(value) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return value
    }
    /^stage_pre_install_source_fixes\(\) \{$/ { in_stage = 1; next }
    in_stage && /^}$/ { in_stage = 0 }
    in_stage && trimmed($0) == "update_oaf_deconfig" {
        if ((getline condition) <= 0 || (getline call) <= 0 || (getline closing_line) <= 0)
            exit 1
        if (trimmed(condition) == "if is_er1_profile; then" &&
            trimmed(call) == "fix_oaf_apk_acl_collision" &&
            trimmed(closing_line) == "fi")
            found = 1
    }
    END { exit(found ? 0 : 1) }
' "$repo_root/wrt_core/update.sh" \
    || fail 'OAF APK ACL collision fix is not ER1-only immediately after update_oaf_deconfig'
rm -f "$oaf_root/luci-app-oaf/root/usr/share/rpcd/acl.d/luci-app-oaf.json"
if fix_oaf_apk_acl_collision >/dev/null 2>&1; then
    fail 'OAF APK ACL collision fix accepted a missing frontend ACL'
fi
printf '%s\n' 'frontend acl' \
    >"$oaf_root/luci-app-oaf/root/usr/share/rpcd/acl.d/luci-app-oaf.json"
printf '%s\n' $'\t$(INSTALL_DATA) ./files/luci-app-oaf.json $(1)/usr/share/rpcd/acl.d/other.json' \
    >"$oaf_root/open-app-filter/Makefile"
if fix_oaf_apk_acl_collision >/dev/null 2>&1; then
    fail 'OAF APK ACL collision fix accepted an unknown install layout'
fi

# A locked Lucky checkout must fail closed when sparse selection fails.
mkdir -p "$tmp/lucky-feed/lucky" "$tmp/lucky-feed/luci-app-lucky"
get_custom_feed_worktree_dir() { printf '%s\n' "$tmp/lucky-feed"; }
git_retry() {
    if [[ ${1:-} == sparse-checkout && ${2:-} == set ]]; then
        return 1
    fi
    return 0
}
checkout_locked_commit() { return 0; }
if update_lucky >/dev/null 2>&1; then
    fail 'Lucky sparse-checkout failure was converted to success'
fi
set +e
(
    set -e
    update_lucky
    : >"$tmp/.wrt-release-build-state"
    : >"$tmp/BUILD_PROVENANCE.txt"
) >/dev/null 2>&1
lucky_stage_status=$?
set -e
[[ $lucky_stage_status -ne 0 ]] || fail 'preparation continued after Lucky sparse-checkout failure'
[[ ! -e "$tmp/.wrt-release-build-state" ]]
[[ ! -e "$tmp/BUILD_PROVENANCE.txt" ]]

# Resume state must bind the prepared source, config, fragments and container.
source "$repo_root/wrt_core/modules/build_state.sh"

# Release-input identity must include Git's line-ending policy for injected helpers.
(
    release_input_root="$tmp/release-input"
    mkdir -p "$release_input_root/wrt_core" "$tmp/release-input-core"
    printf 'attributes one\n' >"$release_input_root/.gitattributes"
    printf '#!/usr/bin/env bash\n' >"$release_input_root/build.sh"
    printf 'source input\n' >"$release_input_root/wrt_core/source"
    printf 'locks\n' >"$tmp/release-input-core/source-locks.env"
    REPO_ROOT="$release_input_root"
    BASE_PATH="$tmp/release-input-core"
    WRT_RELEASE_COMMIT=0123456789012345678901234567890123456789
    WRT_RELEASE_TREE_STATE=dirty
    WRT_RELEASE_INPUT_SHA256=unknown
    BUILD_CONTAINER_IMAGE_ID='sha256:input-test'
    read_ini_by_key() { printf '%s\n' 'container@example'; }
    resolve_release_identity
    attributes_hash_before=$WRT_RELEASE_INPUT_SHA256
    printf 'attributes two\n' >"$release_input_root/.gitattributes"
    WRT_RELEASE_INPUT_SHA256=unknown
    resolve_release_identity
    [[ $WRT_RELEASE_INPUT_SHA256 != "$attributes_hash_before" ]] \
        || fail 'release input ignored .gitattributes changes'
)
git init -q "$tmp/source"
git -C "$tmp/source" config user.name test
git -C "$tmp/source" config user.email test@example.invalid
printf 'CONFIG_TEST=y\nCONFIG_USE_APK=y\n' >"$tmp/source/.config"
printf 'prepared source\n' >"$tmp/source/source-file"
chmod 0644 "$tmp/source/source-file"
git -C "$tmp/source" add .config source-file
git -C "$tmp/source" commit -qm config
Dev=jdcloud_er1_libwrt
WRT_RELEASE_COMMIT=0123456789012345678901234567890123456789
WRT_RELEASE_TREE_STATE=dirty
WRT_RELEASE_INPUT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SOURCE_LOCKS_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
COMMIT_HASH=$(git -C "$tmp/source" rev-parse HEAD)
EFFECTIVE_CONFIG_FRAGMENTS=(nss proxy er1_libwrt_overrides)
BUILD_CONTAINER_BASE='ubuntu@example'
CURRENT_CONTAINER_IMAGE_ID='sha256:container-one'
join_fragments() { local IFS=,; echo "$*"; }
prepare_apk_build_keys "$tmp/source"
[[ $(stat -c '%a' "$tmp/source/private-key.pem") == 600 ]] \
    || fail 'generated APK private key mode is not 600'
validate_apk_build_key_pair "$tmp/source"
expected_apk_public_key_sha256=$(sha256sum "$tmp/source/public-key.pem" | awk '{print $1}')
write_build_state "$tmp/source"
[[ $(build_state_value "$tmp/source/.wrt-release-build-state" ApkBuildPublicKeySha256) \
    == "$expected_apk_public_key_sha256" ]] \
    || fail 'build state omitted or changed the APK public-key fingerprint'
validate_build_state "$tmp/source"
cp -p "$tmp/source/.wrt-release-build-state" "$tmp/build-state.backup"
sed -i 's/^ApkBuildPublicKeySha256: .*/ApkBuildPublicKeySha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
    "$tmp/source/.wrt-release-build-state"
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted a relabeled APK public-key fingerprint'
fi
cp -p "$tmp/build-state.backup" "$tmp/source/.wrt-release-build-state"
cp -p "$tmp/source/private-key.pem" "$tmp/private-key.pem.backup"
cp -p "$tmp/source/public-key.pem" "$tmp/public-key.pem.backup"
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/replacement-private-key.pem"
openssl ec -in "$tmp/replacement-private-key.pem" -pubout \
    -out "$tmp/replacement-public-key.pem" >/dev/null 2>&1
cp "$tmp/replacement-private-key.pem" "$tmp/source/private-key.pem"
cp "$tmp/replacement-public-key.pem" "$tmp/source/public-key.pem"
chmod 0600 "$tmp/source/private-key.pem"
chmod 0644 "$tmp/source/public-key.pem"
validate_apk_build_key_pair "$tmp/source"
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted replacement with a different valid APK key pair'
fi
cp -p "$tmp/private-key.pem.backup" "$tmp/source/private-key.pem"
cp -p "$tmp/public-key.pem.backup" "$tmp/source/public-key.pem"
validate_build_state "$tmp/source"
cp -p "$tmp/source/public-key.pem" "$tmp/public-key.pem.backup"
printf 'mismatched public key\n' >"$tmp/source/public-key.pem"
if validate_apk_build_key_pair "$tmp/source" >/dev/null 2>&1; then
    fail 'APK key-pair validation accepted a mismatched public key'
fi
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted a changed APK public key'
fi
cp -p "$tmp/public-key.pem.backup" "$tmp/source/public-key.pem"
chmod 0644 "$tmp/source/private-key.pem"
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted an insecure APK private-key mode'
fi
chmod 0600 "$tmp/source/private-key.pem"
validate_build_state "$tmp/source"
mkdir -p "$tmp/source/feeds/generated.tmp" "$tmp/source/feeds/luci/modules/luci-base/src/lib"
printf 'generated\n' >"$tmp/source/feeds/generated.tmp/index"
printf 'generated\n' >"$tmp/source/key-build"
printf 'generated\n' >"$tmp/source/feeds/luci/modules/luci-base/src/lib/lmo.o"
validate_build_state "$tmp/source"
mkdir -p "$tmp/source/pkg"
printf 'protected nested key input\n' >"$tmp/source/pkg/private-key.pem"
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume ignored a nested private-key.pem source input'
fi
rm -f "$tmp/source/pkg/private-key.pem"
printf 'protected nested key input\n' >"$tmp/source/pkg/public-key.pem"
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume ignored a nested public-key.pem source input'
fi
rm -f "$tmp/source/pkg/public-key.pem"
printf 'protected object input\n' >"$tmp/source/pkg/input.o"
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted an unrelated object-named source input'
fi
rm -f "$tmp/source/pkg/input.o"
printf 'protected config input\n' >"$tmp/source/pkg/.config-input"
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted a nested config-named source input'
fi
rm -rf "$tmp/source/pkg"
chmod 0755 "$tmp/source/source-file"
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted a mode-only prepared source mutation'
fi
chmod 0644 "$tmp/source/source-file"
WRT_RELEASE_INPUT_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted a changed release input hash'
fi
WRT_RELEASE_INPUT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'modified source\n' >"$tmp/source/source-file"
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted a changed prepared source file'
fi
git -C "$tmp/source" checkout -q -- source-file
WRT_RELEASE_COMMIT=9999999999999999999999999999999999999999
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted relabeled release commit metadata'
fi
WRT_RELEASE_COMMIT=0123456789012345678901234567890123456789
CURRENT_CONTAINER_IMAGE_ID='sha256:container-two'
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted a changed container image ID'
fi

# profiles.json must identify exactly one profile and one supported board.
source "$repo_root/wrt_core/modules/profile_verify.sh"
printf '%s\n' '{"profiles":{"jdcloud_re-cs-07":{"supported_devices":["jdcloud,re-cs-07"]}}}' >"$tmp/profiles.json"
verify_er1_profiles_json "$tmp/profiles.json"
printf '%s\n' '{"profiles":{"jdcloud_re-cs-07":{"supported_devices":["jdcloud,re-cs-07"]},"other":{}}}' >"$tmp/profiles.json"
if verify_er1_profiles_json "$tmp/profiles.json" >/dev/null 2>&1; then
    fail 'profiles gate accepted an additional profile'
fi

echo 'Taiyi build invariant tests passed.'
