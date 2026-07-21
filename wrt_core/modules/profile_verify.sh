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
    local kernel_version
    local selected_devices
    local symbol
    local required_symbols=(
        CONFIG_TARGET_qualcommax
        CONFIG_TARGET_qualcommax_ipq60xx
        CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-07
        CONFIG_TARGET_ROOTFS_SQUASHFS
        CONFIG_PACKAGE_mihomo-meta
        CONFIG_PACKAGE_nikki
        CONFIG_PACKAGE_luci-app-nikki
        CONFIG_PACKAGE_luci-app-homeproxy
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
        CONFIG_PACKAGE_sqm-scripts-nss
        CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe
        CONFIG_PACKAGE_kmod-qca-nss-drv-lag-mgr
    )
    local forbidden_symbols=(
        CONFIG_PACKAGE_luci-app-passwall
        CONFIG_PACKAGE_smartdns
        CONFIG_PACKAGE_luci-app-smartdns
        CONFIG_PACKAGE_luci-app-quickfile
        CONFIG_PACKAGE_quickstart
        CONFIG_PACKAGE_luci-app-quickstart
        CONFIG_PACKAGE_luci-app-uhttpd
        CONFIG_PACKAGE_luci-i18n-uhttpd-zh-cn
        CONFIG_PACKAGE_luci-theme-argon
    )

    for symbol in "${required_symbols[@]}"; do
        assert_config_enabled "$config_path" "$symbol" || return 1
    done

    for symbol in "${forbidden_symbols[@]}"; do
        assert_config_disabled "$config_path" "$symbol" || return 1
    done

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

    kernel_version=$(make --no-print-directory -s -C "$source_dir" kernelversion | tail -n 1)
    if [ "$kernel_version" != "6.12.94" ]; then
        echo "Error: ER1 profile expects kernel 6.12.94, got $kernel_version." >&2
        return 1
    fi

    echo "ER1 profile verified: single RE-CS-07 target, kernel 6.12.94, NSS and package policy OK."
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
