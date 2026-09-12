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
grep -qF 'Using locally verified container base:' "$repo_root/build.sh" \
    || fail 'container preparation does not reuse an exact locally available base image'
grep -qF 'docker pull "$base_image"' "$repo_root/build.sh" \
    || fail 'container preparation does not pull an unavailable exact base image'
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
grep -qF 'audited_builder_image: ${{ vars.TAIYI_BUILDER_IMAGE }}' "$release_workflow" \
    || fail 'release workflow does not require a configured audited builder image'
grep -qF 'audited_builder_manifest_digest: ${{ vars.TAIYI_BUILDER_MANIFEST_DIGEST }}' "$release_workflow" \
    || fail 'release workflow does not require a configured builder manifest digest'
grep -qF 'audited_builder_config_image_id: ${{ vars.TAIYI_BUILDER_CONFIG_IMAGE_ID }}' "$release_workflow" \
    || fail 'release workflow does not require a configured builder config image ID'
grep -qF 'grep -qFx "BuildContainerImageRef: $expected_container_ref" firmware/BUILD_PROVENANCE.txt' \
    "$release_workflow" \
    || fail 'release workflow does not verify the audited builder OCI reference'
grep -qF 'grep -qFx "BuildContainerManifestDigest: $expected_manifest_digest" firmware/BUILD_PROVENANCE.txt' \
    "$release_workflow" \
    || fail 'release workflow does not verify the audited builder manifest digest'
grep -qF 'grep -qFx "BuildContainerImageId: $expected_container_id" firmware/BUILD_PROVENANCE.txt' \
    "$release_workflow" \
    || fail 'release workflow does not verify the audited builder config image ID'
grep -qF 'docker pull "$image"' "$repo_root/.github/workflows/build_wrt.yml" \
    || fail 'build workflow does not pull the configured audited builder'
grep -qF 'actual_config_id=$(docker image inspect --format' "$repo_root/.github/workflows/build_wrt.yml" \
    || fail 'build workflow does not inspect the pulled builder image ID'
grep -qF 'docker run --rm \' "$repo_root/.github/workflows/build_wrt.yml" \
    || fail 'build workflow does not run production builds inside the audited builder'
grep -qF 'grep -qFx "WrtReleaseTreeState: clean" firmware/BUILD_PROVENANCE.txt' \
    "$release_workflow" \
    || fail 'release workflow can publish a dirty-tree build'

apk_repo_policy="$repo_root/wrt_core/patches/995_configure_taiyi_apk_repositories"
plugin_feed_module="$repo_root/wrt_core/modules/plugin_feed.sh"
plugin_feed_dir="$repo_root/wrt_core/taiyi-plugin-feed"
[[ -f $plugin_feed_module ]] || fail 'Taiyi plugin-feed module is missing'
[[ -f $plugin_feed_dir/channel.env && -f $plugin_feed_dir/allowlist ]] \
    || fail 'Taiyi plugin-feed reviewed inputs are missing'
BASE_PATH="$repo_root/wrt_core"
source "$plugin_feed_module"
taiyi_plugin_feed_load_config
[[ $TAIYI_PLUGIN_FEED_MODE == disabled ]] \
    || fail 'blank plugin-feed configuration must leave the channel disabled'
[[ ! -e $plugin_feed_dir/public-key.pem ]] \
    || fail 'disabled plugin-feed configuration must not carry a public key'

# Enable a disposable feed input to prove that the URL, fingerprint and EC key
# are bound before they are copied into the rootfs.
plugin_feed_test_core="$tmp/plugin-feed-core"
mkdir -p "$plugin_feed_test_core/modules" "$plugin_feed_test_core/taiyi-plugin-feed" "$tmp/plugin-feed-rootfs"
cp "$plugin_feed_module" "$plugin_feed_test_core/modules/plugin_feed.sh"
openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/plugin-feed-private.pem"
openssl ec -in "$tmp/plugin-feed-private.pem" -pubout \
    -out "$plugin_feed_test_core/taiyi-plugin-feed/public-key.pem" >/dev/null 2>&1
plugin_feed_test_sha256=$(sha256sum "$plugin_feed_test_core/taiyi-plugin-feed/public-key.pem" | awk '{print $1}')
printf 'TAIYI_PLUGIN_FEED_INDEX_URL=https://packages.example.invalid/taiyi/25.12.2/aarch64_cortex-a53/packages.adb\nTAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256=%s\n' \
    "$plugin_feed_test_sha256" >"$plugin_feed_test_core/taiyi-plugin-feed/channel.env"
printf 'demo-plugin\n' >"$plugin_feed_test_core/taiyi-plugin-feed/allowlist"
BASE_PATH="$plugin_feed_test_core"
source "$plugin_feed_test_core/modules/plugin_feed.sh"
taiyi_plugin_feed_load_config
[[ $TAIYI_PLUGIN_FEED_MODE == enabled ]] \
    || fail 'reviewed plugin-feed inputs did not enable the channel'
install_taiyi_plugin_feed_rootfs "$tmp/plugin-feed-rootfs"
cmp -s "$plugin_feed_test_core/taiyi-plugin-feed/public-key.pem" \
    "$tmp/plugin-feed-rootfs/etc/apk/keys/taiyi-plugin-feed.pem" \
    || fail 'enabled plugin-feed public key was not copied into rootfs'
grep -qFx 'https://packages.example.invalid/taiyi/25.12.2/aarch64_cortex-a53/packages.adb' \
    "$tmp/plugin-feed-rootfs/usr/share/taiyi/apk-plugin-feed" \
    || fail 'enabled plugin-feed URL was not copied into rootfs'
printf 'TAIYI_PLUGIN_FEED_INDEX_URL=https://packages.example.invalid/not-an-index\nTAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256=%s\n' \
    "$plugin_feed_test_sha256" >"$plugin_feed_test_core/taiyi-plugin-feed/channel.env"
if taiyi_plugin_feed_load_config >/dev/null 2>&1; then
    fail 'plugin-feed configuration accepted an invalid index URL'
fi
BASE_PATH="$repo_root/wrt_core"
source "$plugin_feed_module"
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

# An enabled reviewed feed is appended once and does not remove administrator
# custom repositories. The source config remains disabled in this checkout.
printf '%s\n' 'https://packages.example.invalid/taiyi/25.12.2/aarch64_cortex-a53/packages.adb' \
    >"$tmp/taiyi-plugin-feed-url"
printf '%s\n' 'https://admin.example.invalid/packages.adb' \
    >"$tmp/apk-repositories/customfeeds.list"
TAIYI_PLUGIN_FEED_FILE="$tmp/taiyi-plugin-feed-url" \
APK_REPOSITORIES_DIR="$tmp/apk-repositories" \
LEGACY_OPKG_DIR="$tmp/legacy-opkg" \
LEGACY_OPKG_CONF="$tmp/legacy-opkg.conf" \
LEGACY_OPKG_LISTS_DIR="$tmp/legacy-opkg-lists" \
    sh "$apk_repo_policy"
grep -qFx 'https://admin.example.invalid/packages.adb' "$tmp/apk-repositories/customfeeds.list" \
    || fail 'Taiyi plugin feed policy removed an administrator custom feed'
grep -qFx 'https://packages.example.invalid/taiyi/25.12.2/aarch64_cortex-a53/packages.adb' \
    "$tmp/apk-repositories/customfeeds.list" \
    || fail 'Taiyi plugin feed policy did not append the reviewed feed'
[[ $(grep -cFx 'https://packages.example.invalid/taiyi/25.12.2/aarch64_cortex-a53/packages.adb' \
    "$tmp/apk-repositories/customfeeds.list") -eq 1 ]] \
    || fail 'Taiyi plugin feed policy appended the reviewed feed more than once'
printf '%s\n' 'https://packages.example.invalid/not-an-index' >"$tmp/taiyi-plugin-feed-url"
if TAIYI_PLUGIN_FEED_FILE="$tmp/taiyi-plugin-feed-url" \
APK_REPOSITORIES_DIR="$tmp/apk-repositories" \
    sh "$apk_repo_policy" >/dev/null 2>&1; then
    fail 'Taiyi plugin feed policy accepted an invalid baked feed input'
fi

# No profile may recreate the historical unsigned 24.10-SNAPSHOT fallback.
service_fixes="$repo_root/wrt_core/modules/service_fixes.sh"
if grep -qF '24.10-SNAPSHOT' "$service_fixes"; then
    fail 'unsafe 24.10-SNAPSHOT opkg fallback remains reachable'
fi
if grep -Eq 'sed.*check_signature|check_signature.*(0|off|no)' "$service_fixes"; then
    fail 'service fixes can weaken package signature verification'
fi

# The ER1 LuCI backend must reject broad APK upgrades and route an explicit
# reviewed package through the rootfs policy helper.
package_manager_dir="$tmp/package-manager-build/package/feeds/luci/luci-app-package-manager"
mkdir -p "$package_manager_dir/root/usr/libexec"
cat >"$package_manager_dir/root/usr/libexec/package-manager-call" <<'EOF'
#!/bin/sh

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
grep -qF 'Taiyi controlled APK plugin transaction guard' "$package_manager_call" \
    || fail 'Taiyi LuCI package manager does not install the controlled plugin guard'
restrict_er1_luci_apk_upgrade

plugin_test_root="$tmp/taiyi-apk-plugin-policy"
plugin_catalog="$plugin_test_root/catalog"
plugin_baseline="$plugin_test_root/etc/apk-baseline-packages"
plugin_version="$plugin_test_root/version"
plugin_bin="$plugin_test_root/bin"
plugin_policy="$plugin_test_root/policy"
plugin_baseline_init="$plugin_test_root/baseline-init"
mkdir -p "$plugin_test_root" "$plugin_bin" "$plugin_test_root/etc"
cp "$repo_root/wrt_core/patches/taiyi-apk-plugin-catalog" "$plugin_catalog"
printf '1\n' >"$plugin_version"
cat >"$plugin_bin/apk" <<'EOF'
#!/bin/sh
set -eu

case "${1:-}" in
    info)
        printf '%s\n' base-files ddns-go pbr
        ;;
    --simulate)
        [ "${2:-}" = upgrade ] || exit 2
        [ "${APK_SIMULATION_MODE:-success}" = success ] || exit 1
        printf '%s\n' "${APK_SIMULATION_PLAN:-}"
        ;;
    upgrade)
        printf 'upgrade %s\n' "${2:-}" >>"$APK_EXECUTION_LOG"
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod 0755 "$plugin_bin/apk"
sed \
    -e "s|^catalog=.*|catalog=$plugin_catalog|" \
    -e "s|^baseline=.*|baseline=$plugin_baseline|" \
    -e "s|/usr/bin/apk|$plugin_bin/apk|g" \
    "$repo_root/wrt_core/patches/taiyi-apk-plugin-policy" >"$plugin_policy"
chmod 0755 "$plugin_policy"
sed \
    -e "s|^catalog=.*|catalog=$plugin_catalog|" \
    -e "s|^policy_version_file=.*|policy_version_file=$plugin_version|" \
    -e "s|^baseline_dir=.*|baseline_dir=$plugin_test_root/etc|" \
    -e "s|/usr/bin/apk|$plugin_bin/apk|g" \
    "$repo_root/wrt_core/patches/996_capture_taiyi_apk_plugin_baseline" >"$plugin_baseline_init"
chmod 0755 "$plugin_baseline_init"
APK_EXECUTION_LOG="$plugin_test_root/execution.log"
: >"$APK_EXECUTION_LOG"
"$plugin_baseline_init"
grep -qFx '# policy-version: 1' "$plugin_baseline" \
    || fail 'Taiyi plugin baseline did not record its policy version'
grep -qFx 'base-files' "$plugin_baseline" \
    || fail 'Taiyi plugin baseline did not protect the firmware base package'
grep -qFx 'pbr' "$plugin_baseline" \
    || fail 'Taiyi plugin baseline did not protect firmware-only PBR'
if grep -qFx 'ddns-go' "$plugin_baseline"; then
    fail 'Taiyi plugin baseline incorrectly froze a reviewed plugin'
fi

run_plugin_policy() {
    local expected=$1
    shift
    local status

    set +e
    APK_EXECUTION_LOG="$APK_EXECUTION_LOG" \
    APK_SIMULATION_MODE="$APK_SIMULATION_MODE" \
    APK_SIMULATION_PLAN="$APK_SIMULATION_PLAN" \
        "$plugin_policy" "$@" >/dev/null 2>&1
    status=$?
    set -e
    if [[ $expected == success ]]; then
        [[ $status -eq 0 ]] || fail "Taiyi plugin policy unexpectedly rejected: $*"
    else
        [[ $status -ne 0 ]] || fail "Taiyi plugin policy unexpectedly accepted: $*"
    fi
}

APK_SIMULATION_MODE=success
APK_SIMULATION_PLAN='(1/1) Upgrading ddns-go (1.0-r1) to (1.0-r2)'
run_plugin_policy success upgrade ddns-go
grep -qFx 'upgrade ddns-go' "$APK_EXECUTION_LOG" \
    || fail 'Taiyi plugin policy did not execute the approved single-package upgrade'
: >"$APK_EXECUTION_LOG"
APK_SIMULATION_PLAN='(1/2) Upgrading ddns-go (1.0-r1) to (1.0-r2)
(2/2) Upgrading base-files (1.0-r1) to (1.0-r2)'
run_plugin_policy failure upgrade ddns-go
[[ ! -s $APK_EXECUTION_LOG ]] \
    || fail 'Taiyi plugin policy executed after a protected dependency was simulated'
APK_SIMULATION_PLAN='(1/2) Upgrading ddns-go (1.0-r1) to (1.0-r2)
(2/2) Upgrading lucky (1.0-r1) to (1.0-r2)'
run_plugin_policy failure upgrade ddns-go
[[ ! -s $APK_EXECUTION_LOG ]] \
    || fail 'Taiyi plugin policy executed after a second catalog plugin was simulated'
APK_SIMULATION_PLAN='(1/2) Upgrading ddns-go (1.0-r1) to (1.0-r2)
(2/2) Installing arbitrary-userland-dependency (1.0-r1)'
run_plugin_policy failure upgrade ddns-go
[[ ! -s $APK_EXECUTION_LOG ]] \
    || fail 'Taiyi plugin policy executed after an unreviewed dependency was simulated'
APK_SIMULATION_PLAN='Upgrading ddns-go (1.0-r1) to (1.0-r2)'
run_plugin_policy failure upgrade ddns-go
APK_SIMULATION_PLAN='(1/1) Downgrading ddns-go (1.0-r2) to (1.0-r1)'
run_plugin_policy failure upgrade ddns-go
APK_SIMULATION_MODE=failure
APK_SIMULATION_PLAN=''
run_plugin_policy failure upgrade ddns-go
APK_SIMULATION_MODE=success
APK_SIMULATION_PLAN=''
: >"$APK_EXECUTION_LOG"
run_plugin_policy success upgrade ddns-go
grep -qFx 'upgrade ddns-go' "$APK_EXECUTION_LOG" \
    || fail 'Taiyi plugin policy did not preserve a no-op single-package request'
APK_SIMULATION_PLAN='(1/1) Upgrading pbr (1.0-r1) to (1.0-r2)'
run_plugin_policy failure upgrade pbr
run_plugin_policy failure upgrade nikki
run_plugin_policy failure upgrade miniupnpd
run_plugin_policy failure upgrade samba4
run_plugin_policy failure upgrade ddns-go cups
run_plugin_policy failure upgrade

# The patched LuCI backend must use the policy helper instead of falling
# through to a potentially broad upstream upgrade implementation.
sed -i \
    -e 's@if \[ -f /usr/bin/apk \]; then@if true; then@' \
    -e "s|/usr/libexec/taiyi-apk-plugin-policy|$plugin_policy|" \
    "$package_manager_call"
APK_SIMULATION_PLAN='(1/1) Upgrading ddns-go (1.0-r1) to (1.0-r2)'
: >"$APK_EXECUTION_LOG"
backend_output=$(APK_EXECUTION_LOG="$APK_EXECUTION_LOG" \
    APK_SIMULATION_MODE="$APK_SIMULATION_MODE" \
    APK_SIMULATION_PLAN="$APK_SIMULATION_PLAN" \
    sh "$package_manager_call" upgrade ddns-go)
grep -qF '"code":0' <<<"$backend_output" \
    || fail 'Taiyi LuCI package manager did not report a reviewed plugin update success'
grep -qFx 'upgrade ddns-go' "$APK_EXECUTION_LOG" \
    || fail 'Taiyi LuCI package manager did not execute the exact requested package'
backend_output=$(APK_EXECUTION_LOG="$APK_EXECUTION_LOG" \
    APK_SIMULATION_MODE="$APK_SIMULATION_MODE" \
    APK_SIMULATION_PLAN="$APK_SIMULATION_PLAN" \
    sh "$package_manager_call" upgrade)
grep -qF 'Full APK upgrades are disabled on Taiyi' <<<"$backend_output" \
    || fail 'Taiyi LuCI package manager did not reject a broad APK upgrade'

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
[[ $commit_lock_count -eq 16 ]] || fail "expected 16 Git commit locks, got $commit_lock_count"
[[ $OAF_COMMIT =~ ^[0-9a-f]{40}$ ]]
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

# PBR CMCC helpers must retain TLS validation and fail before modifying nft
# when the transport or the complete downloaded CIDR input is invalid.
pbr_helpers=(pbr.user.cmcc pbr.user.cmcc6)
for pbr_helper in "${pbr_helpers[@]}"; do
    pbr_helper_path="$repo_root/wrt_core/patches/$pbr_helper"
    if grep -Eq -- '--no-check-certificate|--insecure|(^|[[:space:]])-k([[:space:]]|$)|check_certificate.*(0|off|no)' \
        "$pbr_helper_path"; then
        fail "$pbr_helper weakens TLS certificate validation"
    fi
    grep -qF 'uclient-fetch -qO ' "$pbr_helper_path" \
        || fail "$pbr_helper does not use the default TLS-validated downloader"
    grep -qF 'nft -c "add element' "$pbr_helper_path" \
        || fail "$pbr_helper does not preflight nft input"
done

pbr_helper_bin="$tmp/pbr-helper-bin"
mkdir -p "$pbr_helper_bin"
cat >"$pbr_helper_bin/uclient-fetch" <<'EOF'
#!/bin/sh
set -eu

printf '%s\n' "$*" >>"$PBR_FETCH_LOG"
out=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -qO)
            out=$2
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
[ -n "$out" ] || exit 2
[ "${PBR_FETCH_MODE:-success}" = success ] || exit 1
cat "$PBR_FETCH_PAYLOAD" >"$out"
EOF
cat >"$pbr_helper_bin/nft" <<'EOF'
#!/bin/sh
set -eu

printf '%s\n' "$*" >>"$PBR_NFT_LOG"
if [ "${1:-}" = -c ] && [ "${PBR_NFT_CHECK_MODE:-success}" != success ]; then
    exit 1
fi
EOF
cat >"$pbr_helper_bin/uci" <<'EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = get ] && [ "${2:-}" = pbr.config.ipv6_enabled ]; then
    printf '%s\n' "${PBR_IPV6_ENABLED:-1}"
fi
EOF
chmod 0755 "$pbr_helper_bin/uclient-fetch" "$pbr_helper_bin/nft" "$pbr_helper_bin/uci"

run_pbr_helper() {
    local helper=$1
    local payload=$2
    local fetch_mode=$3
    local nft_check_mode=$4
    local ipv6_enabled=$5
    local expected_status=$6
    local status

    printf '%s' "$payload" >"$tmp/pbr-helper-payload"
    : >"$tmp/pbr-helper-fetch.log"
    : >"$tmp/pbr-helper-nft.log"
    set +e
    (
        export PATH="$pbr_helper_bin:$PATH"
        export PBR_FETCH_LOG="$tmp/pbr-helper-fetch.log"
        export PBR_FETCH_PAYLOAD="$tmp/pbr-helper-payload"
        export PBR_FETCH_MODE="$fetch_mode"
        export PBR_NFT_LOG="$tmp/pbr-helper-nft.log"
        export PBR_NFT_CHECK_MODE="$nft_check_mode"
        export PBR_IPV6_ENABLED="$ipv6_enabled"
        TARGET_URL=https://example.invalid/cmcc.txt
        TARGET_DL_FILE="$tmp/pbr-helper-cache"
        TARGET_TABLE='inet fw4'
        TARGET_INTERFACE=wan_cmcc
        . "$repo_root/wrt_core/patches/$helper"
    )
    status=$?
    set -e
    if [[ $expected_status == success ]]; then
        [[ $status -eq 0 ]] || fail "$helper unexpectedly rejected valid input"
    else
        [[ $status -ne 0 ]] || fail "$helper accepted invalid or unavailable input"
    fi
}

run_pbr_helper pbr.user.cmcc $'1.2.3.4/24\n203.0.113.0/25\n' success success 1 success
[[ $(wc -l <"$tmp/pbr-helper-nft.log") -eq 2 ]] \
    || fail 'IPv4 helper did not preflight and apply one valid batch'
grep -qF 'add element inet fw4 pbr_wan_cmcc_4_dst_ip_user { 1.2.3.4/24, 203.0.113.0/25 }' \
    "$tmp/pbr-helper-nft.log" || fail 'IPv4 helper changed the validated nft batch'
if grep -Eq -- '--no-check-certificate|--insecure|(^|[[:space:]])-k([[:space:]]|$)' \
    "$tmp/pbr-helper-fetch.log"; then
    fail 'IPv4 helper requested a TLS-bypassing downloader option'
fi
run_pbr_helper pbr.user.cmcc '' failure success 1 failure
[[ ! -s $tmp/pbr-helper-nft.log ]] || fail 'IPv4 fetch failure reached nft'
run_pbr_helper pbr.user.cmcc '' success success 1 failure
[[ ! -s $tmp/pbr-helper-nft.log ]] || fail 'IPv4 empty download reached nft'
run_pbr_helper pbr.user.cmcc $'999.1.1.1/24\n' success success 1 failure
[[ ! -s $tmp/pbr-helper-nft.log ]] || fail 'IPv4 invalid octet reached nft'
run_pbr_helper pbr.user.cmcc $'203.0.113.0/24\nnot-a-cidr\n' success success 1 failure
[[ ! -s $tmp/pbr-helper-nft.log ]] || fail 'IPv4 mixed input reached nft'

run_pbr_helper pbr.user.cmcc6 $'2001:db8::/32\n2001:db8:1::/48\n' success success 1 success
[[ $(wc -l <"$tmp/pbr-helper-nft.log") -eq 2 ]] \
    || fail 'IPv6 helper did not preflight and apply one valid batch'
grep -qF 'add element inet fw4 pbr_wan_cmcc_6_dst_ip_user { 2001:db8::/32, 2001:db8:1::/48 }' \
    "$tmp/pbr-helper-nft.log" || fail 'IPv6 helper changed the validated nft batch'
run_pbr_helper pbr.user.cmcc6 $'2001:db8::/129\n' success success 1 failure
[[ ! -s $tmp/pbr-helper-nft.log ]] || fail 'IPv6 invalid prefix reached nft'
run_pbr_helper pbr.user.cmcc6 $'2001:db8::/32\nmalicious-text\n' success success 1 failure
[[ ! -s $tmp/pbr-helper-nft.log ]] || fail 'IPv6 mixed input reached nft'
run_pbr_helper pbr.user.cmcc6 $'2001:::1/64\n' success failure 1 failure
grep -qFx 'add element inet fw4 pbr_wan_cmcc_6_dst_ip_user { 2001:::1/64 }' \
    "$tmp/pbr-helper-nft.log" && fail 'IPv6 syntax failure reached an nft write'
run_pbr_helper pbr.user.cmcc6 $'2001:db8::/32\n' success success 0 success
[[ ! -s $tmp/pbr-helper-fetch.log && ! -s $tmp/pbr-helper-nft.log ]] \
    || fail 'IPv6-disabled helper performed a download or nft operation'

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
printf '%s\n' 'include $(TOPDIR)/feeds/luci/luci.mk' >"$oaf_root/luci-app-oaf/Makefile"
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
printf '%s\n' \
    'define Package/appfilter/install' \
    $'\t$(INSTALL_DATA) ./files/luci-app-oaf.json $(1)/usr/share/rpcd/acl.d/' \
    'endef' \
    >"$oaf_root/open-app-filter/Makefile"
fix_oaf_apk_acl_collision
grep -qFx $'\t$(INSTALL_DATA) ./files/luci-app-oaf.json $(1)/usr/share/rpcd/acl.d/' \
    "$oaf_root/open-app-filter/Makefile" \
    || fail 'OAF luci.mk layout unexpectedly rewrote its sole backend ACL'
printf '%s\n' 'frontend acl' \
    >"$oaf_root/luci-app-oaf/root/usr/share/rpcd/acl.d/luci-app-oaf.json"
printf '%s\n' $'\t$(INSTALL_DATA) ./files/luci-app-oaf.json $(1)/usr/share/rpcd/acl.d/other.json' \
    >"$oaf_root/open-app-filter/Makefile"
if fix_oaf_apk_acl_collision >/dev/null 2>&1; then
    fail 'OAF APK ACL collision fix accepted an unknown install layout'
fi

# eMMC Health is retained as a user-space candidate only after the legacy
# in-package opkg installer has been removed at build time.
emmc_feed_dir="$tmp/emmc-health"
mkdir -p "$emmc_feed_dir"
cat >"$emmc_feed_dir/Makefile" <<'EOF'
DEPENDS:=+luci-base +luci-js-deps +rpcd
	$(INSTALL_BIN) ./root/usr/libexec/emmc-health $(1)/usr/libexec/emmc-health
	$(INSTALL_BIN) ./root/usr/libexec/emmc-health-install-mmc $(1)/usr/libexec/emmc-health-install-mmc
EOF
source "$repo_root/wrt_core/modules/custom_feed.sh"
fix_emmc_health_luci_js_deps "$emmc_feed_dir"
if grep -qE 'luci-js-deps|emmc-health-install-mmc' "$emmc_feed_dir/Makefile"; then
    fail 'eMMC Health source fix retained a legacy package-manager dependency or installer'
fi

grep -qF 'OAF_COMMIT="b88fcb082597486a816187ec1e02812082161d5e"' \
    "$repo_root/wrt_core/source-locks.env" \
    || fail 'OpenAppFilter upstream commit is not locked'
grep -qF 'destan19/OpenAppFilter|https://github.com/destan19/OpenAppFilter.git|master|$OAF_COMMIT|oaf open-app-filter luci-app-oaf' \
    "$repo_root/wrt_core/modules/custom_feed.sh" \
    || fail 'custom feed does not use the locked OpenAppFilter upstream source'

EASYTIER_AARCH64_RELEASE_SHA256=f533ec25a7ea714e09f645615012200278058525795cc3bb690ff011aec1a70f
CUPS_SOURCE_SHA256=261fd948bce8647b6d5cb2a1784f0c24cc52b5c4e827b71d726020bcc502f3ee
mkdir -p "$tmp/easytier" "$tmp/easytier-marker-only" "$tmp/cups"
printf '%s\n' \
    'PKG_NAME:=easytier' \
    'EASYTIER_SOURCE_SHA256:=f533ec25a7ea714e09f645615012200278058525795cc3bb690ff011aec1a70f' \
    '$(eval $(call BuildPackage,$(PKG_NAME)))' \
    >"$tmp/easytier-marker-only/Makefile"
if fix_easytier_release_integrity "$tmp/easytier-marker-only"; then
    fail 'EasyTier marker-only recipe bypassed archive-integrity validation'
fi
printf '%s\n' \
    'PKG_NAME:=easytier' \
    'define Build/Prepare' \
    'mkdir -p $(PKG_BUILD_DIR)' \
    'if [ ! -f $(PKG_BUILD_DIR)/easytier-core ]; then \\' \
    'wget https://github.com/EasyTier/EasyTier/releases/download/v$(PKG_VERSION)/$(PKG_NAME)-linux-$(APP_ARCH)-v$(PKG_VERSION).zip -O $(PKG_BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION).zip; \\' \
    'unzip -o -j $(PKG_BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION).zip -d $(PKG_BUILD_DIR); \\' \
    'rm -f $(PKG_BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION).zip; \\' \
    'fi' \
    'endef' \
    '$(eval $(call BuildPackage,$(PKG_NAME)))' \
    >"$tmp/easytier/Makefile"
printf '%s\n' 'PKG_MD5SUM:=legacy-md5' >"$tmp/cups/Makefile"
fix_easytier_release_integrity "$tmp/easytier"
fix_cups_source_integrity "$tmp/cups"
grep -qFx "EASYTIER_SOURCE_SHA256:=$EASYTIER_AARCH64_RELEASE_SHA256" \
    "$tmp/easytier/Makefile" \
    || fail 'EasyTier source fix did not inject the locked release SHA-256'
grep -qF 'sha256sum -c -' "$tmp/easytier/Makefile" \
    || fail 'EasyTier source fix did not verify the release archive before extraction'
[[ $(grep -cFx 'define Build/Prepare' "$tmp/easytier/Makefile") -eq 1 ]] \
    || fail 'EasyTier source fix retained an unaudited duplicate prepare block'
grep -qFx "PKG_HASH:=$CUPS_SOURCE_SHA256" "$tmp/cups/Makefile" \
    || fail 'CUPS source fix did not replace the legacy MD5 checksum'
if grep -q '^PKG_MD5SUM:=' "$tmp/cups/Makefile"; then
    fail 'CUPS source fix retained a legacy MD5 checksum'
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

# Candidate staging may contain only explicit non-platform packages and must bind
# clean firmware provenance before any signer sees it.
plugin_stage_root="$tmp/plugin-feed-stage"
mkdir -p "$plugin_stage_root/source" "$plugin_stage_root/packages/custom"
printf 'apk\n' >"$plugin_stage_root/packages/custom/demo-plugin-1.0-r1.apk"
cat >"$plugin_stage_root/catalog" <<'EOF'
safe demo-plugin
firmware-only protected-plugin
EOF
printf 'demo-plugin\n' >"$plugin_stage_root/allowlist"
printf '1\n' >"$plugin_stage_root/policy-version"
openssl ecparam -name prime256v1 -genkey -noout -out "$plugin_stage_root/private-key.pem"
openssl ec -in "$plugin_stage_root/private-key.pem" -pubout \
    -out "$plugin_stage_root/public-key.pem" >/dev/null 2>&1
plugin_stage_key_sha256=$(sha256sum "$plugin_stage_root/public-key.pem" | awk '{print $1}')
cat >"$plugin_stage_root/source/.wrt-release-build-state" <<'EOF'
WrtReleaseCommit: 0123456789012345678901234567890123456789
SourceCommit: 1111111111111111111111111111111111111111
PreparedSourceSha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ConfigSha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
cat >"$plugin_stage_root/BUILD_PROVENANCE.txt" <<EOF
WrtReleaseTreeState: clean
TaiyiPluginFeedMode: enabled
WrtReleaseCommit: 0123456789012345678901234567890123456789
WrtReleaseInputSha256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
SourceCommit: 1111111111111111111111111111111111111111
SourceLocksSha256: dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
PreparedSourceSha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ConfigSha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
TaiyiPluginFeedCatalogSha256: $(sha256sum "$plugin_stage_root/catalog" | awk '{print $1}')
TaiyiPluginFeedAllowlistSha256: $(sha256sum "$plugin_stage_root/allowlist" | awk '{print $1}')
TaiyiPluginPolicyVersionSha256: $(sha256sum "$plugin_stage_root/policy-version" | awk '{print $1}')
TaiyiPluginFeedPublicKeySha256: $plugin_stage_key_sha256
EOF
ALLOW_TAIYI_PLUGIN_FEED_STAGE=1 \
    bash "$repo_root/tools/taiyi-build/publish-plugin-feed.sh" stage \
        --source "$plugin_stage_root/source" \
        --packages "$plugin_stage_root/packages" \
        --catalog "$plugin_stage_root/catalog" \
        --allowlist "$plugin_stage_root/allowlist" \
        --policy-version "$plugin_stage_root/policy-version" \
        --firmware-provenance "$plugin_stage_root/BUILD_PROVENANCE.txt" \
        --output "$plugin_stage_root/candidate"
[[ -f $plugin_stage_root/candidate/packages/demo-plugin-1.0-r1.apk ]] \
    || fail 'Taiyi plugin-feed staging did not copy the approved APK'
grep -qFx 'demo-plugin' "$plugin_stage_root/candidate/PACKAGES" \
    || fail 'Taiyi plugin-feed staging omitted the approved package manifest'
cp -a "$plugin_stage_root/candidate" "$plugin_stage_root/unknown-plan-field"
sed -i 's/^{/{"unexpected":0,/' "$plugin_stage_root/unknown-plan-field/ADDON_PLAN.json"
(
    cd "$plugin_stage_root/unknown-plan-field"
    mapfile -d '' -t candidate_files < <(find . -type f ! -name SHA256SUMS -printf '%P\0' | LC_ALL=C sort -z)
    sha256sum "${candidate_files[@]}" >SHA256SUMS
)
if python3 "$repo_root/tools/taiyi-build/addon-feed-plan.py" verify \
    --candidate "$plugin_stage_root/unknown-plan-field" >/dev/null 2>&1; then
    fail 'Taiyi plugin-feed plan verifier accepted an unknown JSON field'
fi
mkdir -p "$plugin_stage_root/bin"
cat >"$plugin_stage_root/bin/apk" <<'EOF'
#!/bin/sh
set -eu

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output=$2
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
[ -n "${output:-}" ]
printf 'signed index\n' >"$output"
EOF
chmod 0755 "$plugin_stage_root/bin/apk"
ALLOW_TAIYI_PLUGIN_FEED_SIGN=1 \
    bash "$repo_root/tools/taiyi-build/publish-plugin-feed.sh" sign \
        --candidate "$plugin_stage_root/candidate" \
        --output "$plugin_stage_root/signed" \
        --apk "$plugin_stage_root/bin/apk" \
        --private-key "$plugin_stage_root/private-key.pem" \
        --public-key "$plugin_stage_root/public-key.pem" \
        --index-url https://packages.example.invalid/taiyi/25.12.2/aarch64_cortex-a53/packages.adb
[[ -f $plugin_stage_root/signed/demo-plugin-1.0-r1.apk \
    && -s $plugin_stage_root/signed/packages.adb ]] \
    || fail 'Taiyi plugin-feed signer did not emit the exact staged feed files'
printf 'unapproved\n' >"$plugin_stage_root/candidate/packages/unapproved-1.0-r1.apk"
if ALLOW_TAIYI_PLUGIN_FEED_SIGN=1 \
    bash "$repo_root/tools/taiyi-build/publish-plugin-feed.sh" sign \
        --candidate "$plugin_stage_root/candidate" \
        --output "$plugin_stage_root/unexpected-apk-signed" \
        --apk "$plugin_stage_root/bin/apk" \
        --private-key "$plugin_stage_root/private-key.pem" \
        --public-key "$plugin_stage_root/public-key.pem" \
        --index-url https://packages.example.invalid/taiyi/25.12.2/aarch64_cortex-a53/packages.adb >/dev/null 2>&1; then
    fail 'Taiyi plugin-feed signer accepted an APK absent from the hash manifest'
fi
printf 'protected-plugin\n' >"$plugin_stage_root/allowlist"
if ALLOW_TAIYI_PLUGIN_FEED_STAGE=1 \
    bash "$repo_root/tools/taiyi-build/publish-plugin-feed.sh" stage \
        --source "$plugin_stage_root/source" \
        --packages "$plugin_stage_root/packages" \
        --catalog "$plugin_stage_root/catalog" \
        --allowlist "$plugin_stage_root/allowlist" \
        --policy-version "$plugin_stage_root/policy-version" \
        --firmware-provenance "$plugin_stage_root/BUILD_PROVENANCE.txt" \
        --output "$plugin_stage_root/firmware-only-candidate" >/dev/null 2>&1; then
    fail 'Taiyi plugin-feed staging accepted a firmware-only package'
fi

# Resume state must bind the prepared source, config, fragments and container.
BASE_PATH="$repo_root/wrt_core"
source "$repo_root/wrt_core/modules/plugin_feed.sh"
source "$repo_root/wrt_core/modules/build_state.sh"

# Audited builder metadata must be an absent pair or two matching immutable
# OCI values; a half-configured or mismatched pair is fail-closed.
(
    REPO_ROOT="$repo_root"
    BASE_PATH="$repo_root/wrt_core"
    WRT_RELEASE_COMMIT=0123456789012345678901234567890123456789
    WRT_RELEASE_TREE_STATE=clean
    WRT_RELEASE_INPUT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    BUILD_CONTAINER_IMAGE_ID='sha256:container-one'
    BUILD_CONTAINER_IMAGE_REF='registry.example.invalid/taiyi/builder@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    BUILD_CONTAINER_MANIFEST_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    read_ini_by_key() { printf '%s\n' 'ubuntu@example'; }
    resolve_release_identity
)
if (
    REPO_ROOT="$repo_root"
    BASE_PATH="$repo_root/wrt_core"
    WRT_RELEASE_COMMIT=0123456789012345678901234567890123456789
    WRT_RELEASE_TREE_STATE=clean
    WRT_RELEASE_INPUT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    BUILD_CONTAINER_IMAGE_ID='sha256:container-one'
    BUILD_CONTAINER_IMAGE_REF='registry.example.invalid/taiyi/builder@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    BUILD_CONTAINER_MANIFEST_DIGEST='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    read_ini_by_key() { printf '%s\n' 'ubuntu@example'; }
    resolve_release_identity
) >/dev/null 2>&1; then
    fail 'release identity accepted a mismatched builder OCI manifest digest'
fi

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
BUILD_CONTAINER_IMAGE_REF='registry.example.invalid/taiyi/builder@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
BUILD_CONTAINER_MANIFEST_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
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
[[ $(build_state_value "$tmp/source/.wrt-release-build-state" BuildContainerImageRef) \
    == "$BUILD_CONTAINER_IMAGE_REF" ]] \
    || fail 'build state omitted the audited builder OCI reference'
[[ $(build_state_value "$tmp/source/.wrt-release-build-state" BuildContainerManifestDigest) \
    == "$BUILD_CONTAINER_MANIFEST_DIGEST" ]] \
    || fail 'build state omitted the audited builder manifest digest'
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
BUILD_CONTAINER_IMAGE_REF='registry.example.invalid/taiyi/builder@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted a changed builder OCI reference'
fi
BUILD_CONTAINER_IMAGE_REF='registry.example.invalid/taiyi/builder@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
BUILD_CONTAINER_MANIFEST_DIGEST='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
if validate_build_state "$tmp/source" >/dev/null 2>&1; then
    fail 'resume accepted a changed builder manifest digest'
fi
BUILD_CONTAINER_MANIFEST_DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
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
