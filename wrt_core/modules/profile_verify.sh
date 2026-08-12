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
    local required_symbols=(
        CONFIG_TARGET_qualcommax
        CONFIG_TARGET_qualcommax_ipq60xx
        CONFIG_TARGET_DEVICE_qualcommax_ipq60xx_DEVICE_jdcloud_re-cs-07
        CONFIG_TARGET_ROOTFS_SQUASHFS
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

    kernel_patchver=$(sed -n 's/^KERNEL_PATCHVER:=[[:space:]]*//p' \
        "$source_dir/target/linux/qualcommax/Makefile" | head -n 1)
    kernel_suffix=$(sed -n "s/^LINUX_VERSION-${kernel_patchver}[[:space:]]*=[[:space:]]*//p" \
        "$source_dir/target/linux/generic/kernel-${kernel_patchver}" | head -n 1)
    kernel_version="${kernel_patchver}${kernel_suffix}"
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


verify_er1_libwrt_artifacts() {
    local firmware_dir="$1"
    local manifest_path="$firmware_dir/libwrt-qualcommax-ipq60xx.manifest"
    local package_name
    local required_packages=(
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

    if ! grep -q '"jdcloud_re-cs-07"' "$firmware_dir/profiles.json"; then
        echo "Error: ER1 profile missing from profiles.json." >&2
        return 1
    fi

    (cd "$firmware_dir" && sha256sum -c SHA256SUMS) || return 1
    echo "ER1 artifacts verified: manifest policy, profile metadata and SHA-256 checks passed."
}


verify_profile_artifacts() {
    local dev="$1"
    local firmware_dir="$2"

    case "$dev" in
        jdcloud_er1_libwrt)
            verify_er1_libwrt_artifacts "$firmware_dir"
            ;;
    esac
}
