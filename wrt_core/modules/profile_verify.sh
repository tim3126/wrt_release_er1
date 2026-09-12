#!/usr/bin/env bash
# Device-profile assertions evaluated after make defconfig.

assert_config_enabled() {
    local config_path="$1"
    local symbol="$2"

    if ! grep -qx "${symbol}=y" "$config_path"; then
        echo "Error: required config symbol is not enabled: $symbol" >&2
        return 1
    fi
}


assert_config_disabled() {
    local config_path="$1"
    local symbol="$2"

    if grep -qE "^${symbol}=(y|m)$" "$config_path"; then
        echo "Error: forbidden config symbol was enabled: $symbol" >&2
        return 1
    fi
}


verify_er1_libwrt_profile() {
    local config_path="$1"
    local source_dir="$2"
    local expected_commit="$3"
    local actual_commit
    local kernel_patchver
    local kernel_suffix
    local kernel_version
    local selected_devices
    local symbol
    local unexpected_wireless_symbols
    local required_symbols=(
        CONFIG_TARGET_qualcommax
        CONFIG_TARGET_qualcommax_ipq60xx
        CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-07
        CONFIG_TARGET_ROOTFS_SQUASHFS
        CONFIG_USE_APK
        CONFIG_SIGNED_PACKAGES
        CONFIG_DOWNLOAD_CHECK_CERTIFICATE
        CONFIG_PACKAGE_apk-openssl
        CONFIG_PACKAGE_luci-app-package-manager
        CONFIG_PACKAGE_openwrt-keyring
        CONFIG_PACKAGE_mihomo-meta
        CONFIG_PACKAGE_nikki
        CONFIG_PACKAGE_luci-app-nikki
        CONFIG_PACKAGE_luci-app-homeproxy
        CONFIG_PACKAGE_luci-app-adguardhome
        CONFIG_PACKAGE_luci-app-autoreboot
        CONFIG_PACKAGE_luci-app-diskman
        CONFIG_PACKAGE_luci-app-emmc-health
        CONFIG_PACKAGE_luci-app-samba4
        CONFIG_PACKAGE_luci-app-sqm
        CONFIG_PACKAGE_luci-app-oaf
        CONFIG_PACKAGE_luci-app-lucky
        CONFIG_PACKAGE_luci-app-ddns-go
        CONFIG_PACKAGE_luci-app-cupsd
        CONFIG_PACKAGE_luci-app-frpc
        CONFIG_PACKAGE_uhttpd
        CONFIG_PACKAGE_uhttpd-mod-ubus
        CONFIG_PACKAGE_luci-app-vlmcsd
        CONFIG_PACKAGE_luci-app-easytier
        CONFIG_PACKAGE_luci-app-cloudflared
        CONFIG_PACKAGE_luci-app-dockerman
        CONFIG_PACKAGE_docker
        CONFIG_PACKAGE_dockerd
        CONFIG_PACKAGE_openssh-sftp-server
        CONFIG_PACKAGE_luci-app-pbr
        CONFIG_PACKAGE_luci-theme-bootstrap
        CONFIG_PACKAGE_luci-theme-argon
        CONFIG_PACKAGE_sqm-scripts-nss
        CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe
        CONFIG_PACKAGE_kmod-qca-nss-drv-lag-mgr
    )
    local forbidden_symbols=(
        CONFIG_PACKAGE_smartdns
        CONFIG_PACKAGE_luci-app-smartdns
        CONFIG_PACKAGE_luci-app-quickfile
        CONFIG_PACKAGE_quickstart
        CONFIG_PACKAGE_luci-app-quickstart
        CONFIG_PACKAGE_luci-app-istorex
        CONFIG_PACKAGE_luci-app-store
        CONFIG_PACKAGE_luci-app-uhttpd
        CONFIG_PACKAGE_luci-i18n-uhttpd-zh-cn
        CONFIG_PACKAGE_luci-app-passwall
        CONFIG_PACKAGE_luci-i18n-passwall-zh-cn
        CONFIG_PACKAGE_mosdns
        CONFIG_PACKAGE_luci-app-mosdns
        CONFIG_PACKAGE_opkg
        CONFIG_PACKAGE_luci-lib-ipkg
        CONFIG_PACKAGE_ath11k-firmware-ipq6018
        CONFIG_PACKAGE_ath11k-firmware-ipq6018-ddwrt
        CONFIG_PACKAGE_ath11k-firmware-qcn9074
        CONFIG_PACKAGE_kmod-ath11k
        CONFIG_PACKAGE_kmod-ath11k-ahb
        CONFIG_PACKAGE_kmod-ath11k-pci
        CONFIG_PACKAGE_hostapd-common
        CONFIG_PACKAGE_wpad
        CONFIG_PACKAGE_wpad-openssl
        CONFIG_PACKAGE_wpad-basic-openssl
        CONFIG_PACKAGE_wpad-mesh-openssl
    )

    for symbol in "${required_symbols[@]}"; do
        assert_config_enabled "$config_path" "$symbol" || return 1
    done

    for symbol in "${forbidden_symbols[@]}"; do
        assert_config_disabled "$config_path" "$symbol" || return 1
    done

    unexpected_wireless_symbols=$(grep -E \
        '^CONFIG_PACKAGE_(ath11k-firmware[^=]*|kmod-ath11k[^=]*|hostapd[^=]*|wpad[^=]*)=y$' \
        "$config_path" || true)
    if [[ -n "$unexpected_wireless_symbols" ]]; then
        echo "Error: ER1 wired-only profile enabled wireless packages:" >&2
        printf '%s\n' "$unexpected_wireless_symbols" >&2
        return 1
    fi

    selected_devices=$(grep -Ec '^CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_.+=y$' "$config_path" || true)
    if [ "$selected_devices" -ne 1 ]; then
        echo "Error: ER1 profile must select exactly one ipq60xx device; found $selected_devices." >&2
        return 1
    fi

    actual_commit=$(git -C "$source_dir" rev-parse HEAD)
    if [ "$actual_commit" != "$expected_commit" ]; then
        echo "Error: source commit mismatch: expected $expected_commit, got $actual_commit." >&2
        return 1
    fi

    kernel_patchver=$(sed -n 's/^KERNEL_PATCHVER:=[[:space:]]*//p' \
        "$source_dir/target/linux/qualcommax/Makefile" | head -n 1)
    kernel_suffix=$(sed -n "s/^LINUX_VERSION-${kernel_patchver}[[:space:]]*=[[:space:]]*//p" \
        "$source_dir/target/linux/generic/kernel-${kernel_patchver}" | head -n 1)
    kernel_version="${kernel_patchver}${kernel_suffix}"
    if [ "$kernel_version" != "6.12.103" ]; then
        echo "Error: ER1 profile expects kernel 6.12.103, got $kernel_version." >&2
        return 1
    fi

    echo "ER1 profile verified: single RE-CS-07 target, kernel 6.12.103, APK, wired-only NSS and package policy OK."
}


verify_selected_profile() {
    local dev="$1"
    local config_path="$2"
    local source_dir="$3"
    local expected_commit="$4"

    case "$dev" in
        jdcloud_er1_libwrt)
            verify_er1_libwrt_profile "$config_path" "$source_dir" "$expected_commit"
            ;;
    esac
}


verify_er1_image_metadata() {
    local image_path="$1"
    local fwtool_path="$2"
    local expected_device="jdcloud,re-cs-07"
    local metadata_file

    metadata_file=$(mktemp)
    if ! "$fwtool_path" -i "$metadata_file" "$image_path"; then
        rm -f "$metadata_file"
        echo "Error: unable to extract firmware metadata: $image_path" >&2
        return 1
    fi

    if ! python3 - "$metadata_file" "$expected_device" <<'PY'
import json
import sys

metadata_path, expected_device = sys.argv[1:]
with open(metadata_path, "r", encoding="utf-8") as metadata_file:
    metadata = json.load(metadata_file)

supported_devices = metadata.get("supported_devices", [])
if isinstance(supported_devices, str):
    supported_devices = [supported_devices]
if expected_device not in supported_devices:
    raise SystemExit(
        f"expected {expected_device!r} in supported_devices, got {supported_devices!r}"
    )
PY
    then
        rm -f "$metadata_file"
        echo "Error: firmware metadata does not support $expected_device: $image_path" >&2
        return 1
    fi

    rm -f "$metadata_file"
}


verify_er1_rootfs_policy() (
    set -euo pipefail

    local sysupgrade_path="$1"
    local source_dir="$2"
    local unsquashfs="$source_dir/staging_dir/host/bin/unsquashfs4"
    local work_dir
    local root_member
    local rootfs
    local helper
    local forbidden_path
    local private_key_path
    local openssl_bin
    local derived_public_key
    local plugin_feed_mode
    local plugin_feed_key_sha256
    local -a root_members=()
    local -a helpers=(
        sbin/cpuusage
        sbin/tempinfo
        etc/init.d/smp_affinity
        usr/share/pbr/pbr.user.cmcc
        usr/share/pbr/pbr.user.cmcc6
    )
    local -a required_paths=(
        usr/bin/apk
        lib/apk/db
        etc/apk/keys/openwrt-25.12.pem
        etc/apk/keys/immortalwrt-25.12.pem
        etc/apk/keys/public-key.pem
        etc/apk/repositories.d/distfeeds.list
        etc/apk/repositories.d/customfeeds.list
        etc/uci-defaults/995_configure_taiyi_apk_repositories
        etc/uci-defaults/996_capture_taiyi_apk_plugin_baseline
        usr/libexec/taiyi-apk-plugin-policy
        usr/share/taiyi/apk-plugin-catalog
        usr/share/taiyi/apk-plugin-policy-version
    )
    local -a forbidden_paths=(
        bin/opkg
        usr/bin/opkg
        etc/opkg.conf
        etc/opkg
        usr/lib/opkg
        private-key.pem
        etc/apk/keys/private-key.pem
        etc/uci-defaults/991_custom_settings
        etc/uci-defaults/993_disable_unpublished_distfeeds
    )

    if [[ ! -x $unsquashfs ]]; then
        echo "Error: unsquashfs4 not found or not executable: $unsquashfs" >&2
        return 1
    fi

    work_dir=$(mktemp -d)
    trap 'rm -rf "$work_dir"' EXIT INT TERM
    root_member="$work_dir/root.squashfs"
    rootfs="$work_dir/rootfs"

    mapfile -t root_members < <(tar -tf "$sysupgrade_path" | grep -E '^sysupgrade-[^/]+/root$')
    if [[ ${#root_members[@]} -ne 1 ]]; then
        echo "Error: expected one root member in $sysupgrade_path; found ${#root_members[@]}." >&2
        return 1
    fi
    tar -xOf "$sysupgrade_path" "${root_members[0]}" >"$root_member"
    "$unsquashfs" -q -d "$rootfs" "$root_member"

    for helper in "${helpers[@]}"; do
        if [[ ! -x $rootfs/$helper ]]; then
            echo "Error: required helper is missing or not executable in rootfs: $helper" >&2
            return 1
        fi
        if LC_ALL=C grep -q $'\r' "$rootfs/$helper"; then
            echo "Error: CR byte found in packaged helper: $helper" >&2
            return 1
        fi
        if ! head -n 1 "$rootfs/$helper" | grep -q '^#!/bin/sh'; then
            echo "Error: packaged helper has an invalid shell shebang: $helper" >&2
            return 1
        fi
    done

    for helper in "${required_paths[@]}"; do
        if [[ ! -e $rootfs/$helper ]]; then
            echo "Error: required APK rootfs path is missing: $helper" >&2
            return 1
        fi
    done

    taiyi_plugin_feed_load_config || return 1
    plugin_feed_mode=$TAIYI_PLUGIN_FEED_MODE
    case "$plugin_feed_mode" in
        disabled)
            if [[ -e $rootfs/etc/apk/keys/taiyi-plugin-feed.pem \
                || -e $rootfs/usr/share/taiyi/apk-plugin-feed ]]; then
                echo "Error: disabled Taiyi plugin feed leaked rootfs inputs." >&2
                return 1
            fi
            ;;
        enabled)
            if [[ ! -f $rootfs/etc/apk/keys/taiyi-plugin-feed.pem \
                || -L $rootfs/etc/apk/keys/taiyi-plugin-feed.pem \
                || ! -f $rootfs/usr/share/taiyi/apk-plugin-feed ]]; then
                echo "Error: enabled Taiyi plugin feed rootfs inputs are missing." >&2
                return 1
            fi
            plugin_feed_key_sha256=$(sha256sum "$rootfs/etc/apk/keys/taiyi-plugin-feed.pem" | awk '{print $1}')
            if [[ $plugin_feed_key_sha256 != "$TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256" ]] \
                || ! cmp -s "$rootfs/usr/share/taiyi/apk-plugin-feed" \
                    <(printf '%s\n' "$TAIYI_PLUGIN_FEED_INDEX_URL"); then
                echo "Error: enabled Taiyi plugin feed differs from reviewed build inputs." >&2
                return 1
            fi
            ;;
        *)
            echo "Error: unknown Taiyi plugin feed mode: $plugin_feed_mode" >&2
            return 1
            ;;
    esac

    if [[ ! -x $rootfs/etc/uci-defaults/995_configure_taiyi_apk_repositories ]]; then
        echo "Error: Taiyi APK repository policy is not executable." >&2
        return 1
    fi
    if [[ ! -x $rootfs/etc/uci-defaults/996_capture_taiyi_apk_plugin_baseline ]]; then
        echo "Error: Taiyi APK plugin baseline initializer is not executable." >&2
        return 1
    fi
    if [[ ! -x $rootfs/usr/libexec/taiyi-apk-plugin-policy ]]; then
        echo "Error: Taiyi APK plugin transaction policy is not executable." >&2
        return 1
    fi
    if LC_ALL=C grep -q $'\r' "$rootfs/etc/uci-defaults/995_configure_taiyi_apk_repositories" \
        || LC_ALL=C grep -q $'\r' "$rootfs/etc/uci-defaults/996_capture_taiyi_apk_plugin_baseline" \
        || LC_ALL=C grep -q $'\r' "$rootfs/usr/libexec/taiyi-apk-plugin-policy" \
        || LC_ALL=C grep -q $'\r' "$rootfs/usr/share/taiyi/apk-plugin-catalog"; then
        echo "Error: CR byte found in a Taiyi APK policy input." >&2
        return 1
    fi
    if ! grep -Eq '^[1-9][0-9]*$' "$rootfs/usr/share/taiyi/apk-plugin-policy-version" \
        || [[ $(wc -l <"$rootfs/usr/share/taiyi/apk-plugin-policy-version") -ne 1 ]]; then
        echo "Error: Taiyi APK plugin policy version is invalid." >&2
        return 1
    fi
    if ! awk '
        /^#/ || NF == 0 { next }
        NF != 2 { invalid = 1; next }
        $1 == "safe" { safe = 1 }
        $1 == "network-critical" { critical = 1 }
        $1 == "firmware-only" { firmware = 1 }
        $1 != "safe" && $1 != "network-critical" && $1 != "firmware-only" { invalid = 1 }
        $2 !~ /^[A-Za-z0-9][A-Za-z0-9+_.-]*$/ { invalid = 1 }
        ++seen[$2] != 1 { invalid = 1 }
        END { exit invalid || !(safe && critical && firmware) }
    ' "$rootfs/usr/share/taiyi/apk-plugin-catalog"; then
        echo "Error: Taiyi APK plugin catalog is invalid." >&2
        return 1
    fi
    if ! grep -qF 'if [ "$package_name" != "$requested_package" ]; then' \
        "$rootfs/usr/libexec/taiyi-apk-plugin-policy"; then
        echo "Error: Taiyi APK plugin policy does not enforce exact package plans." >&2
        return 1
    fi
    if ! grep -qFx 'firmware-only pbr' "$rootfs/usr/share/taiyi/apk-plugin-catalog" \
        || ! grep -qFx 'firmware-only nikki' "$rootfs/usr/share/taiyi/apk-plugin-catalog" \
        || ! grep -qFx 'firmware-only miniupnpd' "$rootfs/usr/share/taiyi/apk-plugin-catalog" \
        || ! grep -qFx 'firmware-only samba4' "$rootfs/usr/share/taiyi/apk-plugin-catalog" \
        || ! grep -qFx 'firmware-only kmod-oaf' "$rootfs/usr/share/taiyi/apk-plugin-catalog" \
        || ! grep -qFx 'firmware-only luci-lib-docker' "$rootfs/usr/share/taiyi/apk-plugin-catalog"; then
        echo "Error: Taiyi APK plugin catalog does not protect firmware-only packages." >&2
        return 1
    fi

    for forbidden_path in "${forbidden_paths[@]}"; do
        if [[ -e $rootfs/$forbidden_path ]]; then
            echo "Error: forbidden opkg, private-key or first-boot path is present: $forbidden_path" >&2
            return 1
        fi
    done
    if [[ ! -f $source_dir/private-key.pem || -L $source_dir/private-key.pem ]]; then
        echo "Error: APK build private key is missing or is not a regular file." >&2
        return 1
    fi
    if [[ ! -f $source_dir/public-key.pem || -L $source_dir/public-key.pem ]]; then
        echo "Error: APK build public key is missing or is not a regular file." >&2
        return 1
    fi
    openssl_bin=$(command -v openssl || true)
    if [[ -z $openssl_bin ]]; then
        echo "Error: openssl is required to verify the APK build key pair." >&2
        return 1
    fi
    derived_public_key="$work_dir/derived-public-key.pem"
    if ! "$openssl_bin" ec -in "$source_dir/private-key.pem" \
        -pubout -out "$derived_public_key" >/dev/null 2>&1; then
        echo "Error: unable to derive the APK public key from the private key." >&2
        return 1
    fi
    if ! cmp -s "$derived_public_key" "$source_dir/public-key.pem"; then
        echo "Error: APK build private and public keys do not form a pair." >&2
        return 1
    fi
    if [[ -L $rootfs/etc/apk/keys/public-key.pem ]]; then
        echo "Error: packaged APK build public key must not be a symbolic link." >&2
        return 1
    fi
    if ! cmp -s "$source_dir/public-key.pem" "$rootfs/etc/apk/keys/public-key.pem"; then
        echo "Error: packaged APK build public key differs from the build-tree public key." >&2
        return 1
    fi
    private_key_path=$(find "$rootfs" -name 'private-key.pem' -print -quit)
    if [[ -n $private_key_path ]]; then
        echo "Error: APK private key leaked into the packaged rootfs." >&2
        return 1
    fi

    mkdir -p "$work_dir/effective-repositories" \
        "$work_dir/legacy-opkg" "$work_dir/legacy-opkg-lists"
    cp "$rootfs/etc/apk/repositories.d/customfeeds.list" \
        "$work_dir/effective-repositories/customfeeds.list"
    printf 'legacy\n' >"$work_dir/legacy-opkg/distfeeds.conf"
    printf 'legacy\n' >"$work_dir/legacy-opkg.conf"
    printf 'legacy\n' >"$work_dir/legacy-opkg-lists/index"
    APK_REPOSITORIES_DIR="$work_dir/effective-repositories" \
    LEGACY_OPKG_DIR="$work_dir/legacy-opkg" \
    LEGACY_OPKG_CONF="$work_dir/legacy-opkg.conf" \
    LEGACY_OPKG_LISTS_DIR="$work_dir/legacy-opkg-lists" \
        sh "$rootfs/etc/uci-defaults/995_configure_taiyi_apk_repositories"

    cat >"$work_dir/expected-distfeeds.list" <<'EOF'
# Taiyi user-space feeds. Public target and kmods feeds are intentionally omitted.
https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_cortex-a53/base/packages.adb
https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_cortex-a53/luci/packages.adb
https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_cortex-a53/packages/packages.adb
https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_cortex-a53/routing/packages.adb
https://mirror.nju.edu.cn/immortalwrt/releases/25.12.2/packages/aarch64_cortex-a53/telephony/packages.adb
EOF
    if ! cmp -s "$work_dir/expected-distfeeds.list" \
        "$work_dir/effective-repositories/distfeeds.list"; then
        echo "Error: effective Taiyi APK repository set differs from policy." >&2
        return 1
    fi
    if grep -Eq '/targets/|/kmods/' "$work_dir/effective-repositories/distfeeds.list"; then
        echo "Error: effective Taiyi APK repositories include public target or kmods feeds." >&2
        return 1
    fi
    if [[ -e $work_dir/legacy-opkg || -e $work_dir/legacy-opkg.conf \
        || -e $work_dir/legacy-opkg-lists ]]; then
        echo "Error: retained opkg configuration was not removed by the migration policy." >&2
        return 1
    fi

    echo "ER1 rootfs verified: APK-only policy, signed-feed keys, LF helpers and first-boot safeguards OK."
)


verify_er1_libwrt_images() {
    local firmware_dir="$1"
    local source_dir="$2"
    local fwtool_path="$source_dir/staging_dir/host/bin/fwtool"
    local image_path
    local image_name
    local image_hash
    local -a all_bin_images=()
    local -a factory_images=()
    local -a sysupgrade_images=()

    mapfile -d '' all_bin_images < <(find "$firmware_dir" -maxdepth 1 -type f -name '*.bin' -print0)
    mapfile -d '' factory_images < <(find "$firmware_dir" -maxdepth 1 -type f \
        -name '*-jdcloud_re-cs-07-squashfs-factory.bin' -print0)
    mapfile -d '' sysupgrade_images < <(find "$firmware_dir" -maxdepth 1 -type f \
        -name '*-jdcloud_re-cs-07-squashfs-sysupgrade.bin' -print0)

    if [[ ${#factory_images[@]} -ne 1 ]]; then
        echo "Error: expected exactly one RE-CS-07 factory image; found ${#factory_images[@]}." >&2
        return 1
    fi
    if [[ ${#sysupgrade_images[@]} -ne 1 ]]; then
        echo "Error: expected exactly one RE-CS-07 sysupgrade image; found ${#sysupgrade_images[@]}." >&2
        return 1
    fi
    if [[ ${#all_bin_images[@]} -ne 2 ]]; then
        echo "Error: expected only the two RE-CS-07 .bin images; found ${#all_bin_images[@]}." >&2
        printf 'Unexpected image set: %s\n' "${all_bin_images[*]}" >&2
        return 1
    fi
    if [[ ! -x $fwtool_path ]]; then
        echo "Error: fwtool not found or not executable: $fwtool_path" >&2
        return 1
    fi
    if [[ ! -f $firmware_dir/SHA256SUMS ]]; then
        echo "Error: SHA256SUMS not found: $firmware_dir/SHA256SUMS" >&2
        return 1
    fi

    for image_path in "${factory_images[@]}" "${sysupgrade_images[@]}"; do
        if [[ ! -s $image_path ]]; then
            echo "Error: firmware image is empty: $image_path" >&2
            return 1
        fi

        image_name=$(basename "$image_path")
        image_hash=$(sha256sum "$image_path" | awk '{print $1}')
        if ! grep -Fqx "$image_hash  $image_name" "$firmware_dir/SHA256SUMS"; then
            echo "Error: firmware image hash is missing or stale in SHA256SUMS: $image_name" >&2
            return 1
        fi

        verify_er1_image_metadata "$image_path" "$fwtool_path" || return 1
    done

    verify_er1_rootfs_policy "${sysupgrade_images[0]}" "$source_dir" || return 1

    echo "ER1 image set verified: one factory image and one sysupgrade image, both for jdcloud,re-cs-07."
}


verify_er1_profiles_json() {
    local profiles_path="$1"

    if ! jq -e '
        (.profiles | type == "object") and
        (.profiles | length == 1) and
        (.profiles | has("jdcloud_re-cs-07")) and
        (.profiles["jdcloud_re-cs-07"].supported_devices == ["jdcloud,re-cs-07"])
    ' "$profiles_path" >/dev/null; then
        echo "Error: profiles.json must contain exactly the jdcloud_re-cs-07 profile and board." >&2
        return 1
    fi
}


verify_er1_libwrt_artifacts() {
    local firmware_dir="$1"
    local source_dir="$2"
    local manifest_path="$firmware_dir/libwrt-qualcommax-ipq60xx.manifest"
    local package_name
    local required_packages=(
        apk-openssl openwrt-keyring luci-app-package-manager
        mihomo-meta nikki luci-app-nikki
        luci-app-homeproxy
        luci-app-adguardhome luci-app-autoreboot luci-app-diskman
        luci-app-emmc-health luci-app-samba4 luci-app-sqm
        appfilter kmod-oaf luci-app-oaf lucky luci-app-lucky
        ddns-go luci-app-ddns-go cups luci-app-cupsd
        frpc luci-app-frpc uhttpd uhttpd-mod-ubus
        vlmcsd luci-app-vlmcsd easytier luci-app-easytier
        cloudflared luci-app-cloudflared docker dockerd luci-app-dockerman
        openssh-sftp-server pbr luci-app-pbr
        luci-theme-bootstrap luci-theme-argon
        kmod-qca-nss-dp kmod-qca-nss-drv kmod-qca-nss-ecm kmod-qca-ssdk
        sqm-scripts-nss
    )
    local forbidden_packages=(
        opkg luci-lib-ipkg
        smartdns luci-app-smartdns luci-i18n-smartdns-zh-cn
        quickfile luci-app-quickfile quickstart luci-app-quickstart
        luci-app-istorex luci-app-store
        luci-app-uhttpd luci-i18n-uhttpd-zh-cn
        mosdns luci-app-mosdns luci-app-passwall luci-i18n-passwall-zh-cn
    )

    if [ ! -f "$manifest_path" ]; then
        echo "Error: ER1 manifest not found: $manifest_path" >&2
        return 1
    fi

    for package_name in "${required_packages[@]}"; do
        if ! grep -qE "^${package_name} - " "$manifest_path"; then
            echo "Error: required ER1 package missing from manifest: $package_name" >&2
            return 1
        fi
    done

    for package_name in "${forbidden_packages[@]}"; do
        if grep -qE "^${package_name} - " "$manifest_path"; then
            echo "Error: forbidden ER1 package present in manifest: $package_name" >&2
            return 1
        fi
    done

    verify_er1_libwrt_images "$firmware_dir" "$source_dir" || return 1

    verify_er1_profiles_json "$firmware_dir/profiles.json" || return 1

    (cd "$firmware_dir" && sha256sum -c SHA256SUMS) || return 1
    echo "ER1 artifacts verified: manifest policy, profile metadata and SHA-256 checks passed."
}


verify_profile_artifacts() {
    local dev="$1"
    local firmware_dir="$2"
    local source_dir="$3"

    case "$dev" in
        jdcloud_er1_libwrt)
            verify_er1_libwrt_artifacts "$firmware_dir" "$source_dir"
            ;;
    esac
}
