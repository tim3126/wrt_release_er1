#!/usr/bin/env bash
# install_feeds 前的 feed 工作树修正。

remove_unwanted_packages() {
    # 移除将由 custom_feed 接管或会产生冲突的上游包。
    local luci_packages=(
        "luci-app-ddns-go" "luci-app-rclone" "luci-app-ssr-plus"
        "luci-app-vssr" "luci-app-daed" "luci-app-dae" "luci-app-alist" "luci-app-homeproxy"
        "luci-app-haproxy-tcp" "luci-app-openclash" "luci-app-mihomo" "luci-app-appfilter"
        "luci-app-msd_lite" "luci-app-unblockneteasemusic" "luci-app-adguardhome"
    )
    local packages_net=(
        "haproxy" "xray-core" "xray-plugin" "dns2socks" "alist" "hysteria"
        "mosdns" "adguardhome" "ddns-go" "naiveproxy" "shadowsocks-rust"
        "sing-box" "v2ray-core" "v2ray-geodata" "v2ray-plugin" "tuic-client"
        "chinadns-ng" "ipt2socks" "tcping" "trojan-plus" "simple-obfs" "shadowsocksr-libev"
        "dae" "daed" "mihomo" "geoview" "open-app-filter" "msd_lite"
    )
    local packages_utils=(
        "cups"
    )
    for pkg in "${luci_packages[@]}"; do
        if [[ -d ./feeds/luci/applications/$pkg ]]; then
            \rm -rf ./feeds/luci/applications/$pkg
        fi
        if [[ -d ./feeds/luci/themes/$pkg ]]; then
            \rm -rf ./feeds/luci/themes/$pkg
        fi
    done

    for pkg in "${packages_net[@]}"; do
        if [[ -d ./feeds/packages/net/$pkg ]]; then
            \rm -rf ./feeds/packages/net/$pkg
        fi
    done

    for pkg in "${packages_utils[@]}"; do
        if [[ -d ./feeds/packages/utils/$pkg ]]; then
            \rm -rf ./feeds/packages/utils/$pkg
        fi
    done

    if [[ -d ./package/istore ]]; then
        \rm -rf ./package/istore
    fi

    if [ -d "$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults" ]; then
        find "$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults/" -type f -name "99*.sh" -exec rm -f {} +
    fi
}


update_homeproxy() {
    local repo_url="https://github.com/immortalwrt/homeproxy.git"
    local target_dir="$(get_custom_feed_worktree_dir)/luci-app-homeproxy"

    if [ -d "$target_dir" ]; then
        echo "正在更新 homeproxy..."
        rm -rf "$target_dir"
        if ! git_retry clone --depth 1 "$repo_url" "$target_dir" || ! checkout_locked_commit "$target_dir" "$HOMEPROXY_COMMIT"; then
            echo "错误：从 $repo_url 检出 homeproxy@$HOMEPROXY_COMMIT 失败" >&2
            exit 1
        fi
    fi
}


update_lucky() {
    local lucky_repo_url="https://github.com/gdy666/luci-app-lucky.git"
    local target_custom_feed_dir="$(get_custom_feed_worktree_dir)"
    local lucky_dir="$target_custom_feed_dir/lucky"
    local luci_app_lucky_dir="$target_custom_feed_dir/luci-app-lucky"

    if [ ! -d "$lucky_dir" ] || [ ! -d "$luci_app_lucky_dir" ]; then
        echo "Warning: $lucky_dir 或 $luci_app_lucky_dir 不存在，跳过 lucky 源代码更新。" >&2
    else
        local tmp_dir
        tmp_dir=$(mktemp -d)

        echo "正在从 $lucky_repo_url 稀疏检出 luci-app-lucky 和 lucky..."

        if ! git_retry clone --depth 1 --filter=blob:none --no-checkout "$lucky_repo_url" "$tmp_dir" || ! checkout_locked_commit "$tmp_dir" "$LUCKY_COMMIT"; then
            echo "错误：从 $lucky_repo_url 检出 lucky@$LUCKY_COMMIT 失败" >&2
            rm -rf "$tmp_dir"
            return 1
        fi

        pushd "$tmp_dir" >/dev/null
        git_retry sparse-checkout init --cone
        git_retry sparse-checkout set luci-app-lucky lucky || {
            echo "错误：稀疏检出 luci-app-lucky 或 lucky 失败" >&2
            popd >/dev/null
            rm -rf "$tmp_dir"
            return 1
        }
        git_retry checkout --quiet "$LUCKY_COMMIT"

        \cp -rf "$tmp_dir/luci-app-lucky/." "$luci_app_lucky_dir/"
        \cp -rf "$tmp_dir/lucky/." "$lucky_dir/"

        popd >/dev/null
        rm -rf "$tmp_dir"
        echo "luci-app-lucky 和 lucky 源代码更新完成。"
    fi

    local lucky_conf="$(get_custom_feed_worktree_dir)/lucky/files/luckyuci"
    if [ -f "$lucky_conf" ]; then
        sed -i "s/option enabled '1'/option enabled '0'/g" "$lucky_conf"
        sed -i "s/option logger '1'/option logger '0'/g" "$lucky_conf"
    fi

    local version
    version=$(find "$BASE_PATH/patches" -name "lucky_*.tar.gz" -printf "%f\n" | head -n 1 | sed -n 's/^lucky_\(.*\)_Linux.*$/\1/p')
    if [ -z "$version" ]; then
        echo "Warning: 未找到 lucky 补丁文件，跳过更新。" >&2
        return 0
    fi

    local makefile_path="$(get_custom_feed_worktree_dir)/lucky/Makefile"
    if [ ! -f "$makefile_path" ]; then
        echo "Warning: lucky Makefile not found. Skipping." >&2
        return 0
    fi

    echo "正在更新 lucky Makefile..."
    local patch_line="\\t[ -f \$(TOPDIR)/../wrt_core/patches/lucky_${version}_Linux_\$(LUCKY_ARCH)_wanji.tar.gz ] && install -Dm644 \$(TOPDIR)/../wrt_core/patches/lucky_${version}_Linux_\$(LUCKY_ARCH)_wanji.tar.gz \$(PKG_BUILD_DIR)/\$(PKG_NAME)_\$(PKG_VERSION)_Linux_\$(LUCKY_ARCH).tar.gz"

    if grep -q "Build/Prepare" "$makefile_path"; then
        sed -i "/Build\\/Prepare/a\\$patch_line" "$makefile_path"
        sed -i '/wget/d' "$makefile_path"
        echo "lucky Makefile 更新完成。"
    else
        echo "Warning: lucky Makefile 中未找到 'Build/Prepare'。跳过。" >&2
    fi
}


remove_attendedsysupgrade() {
    find "$BUILD_DIR/feeds/luci/collections" -name "Makefile" | while read -r makefile; do
        if grep -q "luci-app-attendedsysupgrade" "$makefile"; then
            sed -i "/luci-app-attendedsysupgrade/d" "$makefile"
            echo "Removed luci-app-attendedsysupgrade from $makefile"
        fi
    done
}


fix_mkpkg_format_invalid() {
    local custom_feed_worktree_dir
    custom_feed_worktree_dir=$(get_custom_feed_worktree_dir)

    if [[ $BUILD_DIR =~ "imm-nss" ]]; then
        if [ -f "$custom_feed_worktree_dir/v2ray-geodata/Makefile" ]; then
            sed -i 's/VER)-\$(PKG_RELEASE)/VER)-r\$(PKG_RELEASE)/g' "$custom_feed_worktree_dir/v2ray-geodata/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-lib-taskd/Makefile" ]; then
            sed -i 's/>=1\.0\.3-1/>=1\.0\.3-r1/g' "$custom_feed_worktree_dir/luci-lib-taskd/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-app-openclash/Makefile" ]; then
            sed -i 's/PKG_RELEASE:=beta/PKG_RELEASE:=1/g' "$custom_feed_worktree_dir/luci-app-openclash/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-app-quickstart/Makefile" ]; then
            sed -i 's/PKG_VERSION:=0\.8\.16-1/PKG_VERSION:=0\.8\.16/g' "$custom_feed_worktree_dir/luci-app-quickstart/Makefile"
            sed -i 's/PKG_RELEASE:=$/PKG_RELEASE:=1/g' "$custom_feed_worktree_dir/luci-app-quickstart/Makefile"
        fi
        if [ -f "$custom_feed_worktree_dir/luci-app-store/Makefile" ]; then
            sed -i 's/PKG_VERSION:=0\.1\.27-1/PKG_VERSION:=0\.1\.27/g' "$custom_feed_worktree_dir/luci-app-store/Makefile"
            sed -i 's/PKG_RELEASE:=$/PKG_RELEASE:=1/g' "$custom_feed_worktree_dir/luci-app-store/Makefile"
        fi
    fi
}


fix_luci_docker_apk_versions() {
    local relative_path
    local expected_version
    local normalized_version
    local makefile_path
    local declaration_count
    local current_version
    local tmp_path
    local package_spec
    local package_specs=(
        "feeds/luci/libs/luci-lib-docker/Makefile|v0.3.4|0.3.4"
        "feeds/luci/applications/luci-app-dockerman/Makefile|v0.5.26|0.5.26"
    )

    for package_spec in "${package_specs[@]}"; do
        IFS='|' read -r relative_path expected_version normalized_version <<<"$package_spec"
        makefile_path="$BUILD_DIR/$relative_path"
        if [[ ! -f $makefile_path || -L $makefile_path ]]; then
            echo "Error: required LuCI Docker Makefile is missing or is a symlink: $makefile_path" >&2
            return 1
        fi
        declaration_count=$(grep -c '^PKG_VERSION:=' "$makefile_path" || true)
        if [[ $declaration_count -ne 1 ]]; then
            echo "Error: expected one PKG_VERSION declaration in $makefile_path, got $declaration_count" >&2
            return 1
        fi
        current_version=$(sed -n 's/^PKG_VERSION:=//p' "$makefile_path")
        case "$current_version" in
            "$expected_version")
                tmp_path="$makefile_path.tmp.$$"
                if ! awk -v from="PKG_VERSION:=$expected_version" \
                    -v to="PKG_VERSION:=$normalized_version" \
                    '{ if ($0 == from) print to; else print }' \
                    "$makefile_path" >"$tmp_path"; then
                    rm -f "$tmp_path"
                    return 1
                fi
                if ! chmod --reference="$makefile_path" "$tmp_path" \
                    || ! mv -f "$tmp_path" "$makefile_path"; then
                    rm -f "$tmp_path"
                    return 1
                fi
                ;;
            "$normalized_version")
                ;;
            *)
                echo "Error: unsupported LuCI Docker package version '$current_version' in $makefile_path" >&2
                return 1
                ;;
        esac
        if ! grep -qFx "PKG_VERSION:=$normalized_version" "$makefile_path"; then
            echo "Error: failed to normalize LuCI Docker APK version in $makefile_path" >&2
            return 1
        fi
    done
}


update_tcping() {
    local tcping_path="$(get_custom_feed_worktree_dir)/tcping/Makefile"
    local url="https://raw.githubusercontent.com/Openwrt-Passwall/openwrt-passwall-packages/${PASSWALL_PACKAGES_COMMIT}/tcping/Makefile"

    if [ -d "$(dirname "$tcping_path")" ]; then
        echo "正在更新 tcping Makefile..."
        if ! curl_retry -fsSL -o "$tcping_path" "$url"; then
            echo "错误：从 $url 下载 tcping Makefile 失败" >&2
            exit 1
        fi
    fi
}


fix_quickstart() {
    local file_path="$(get_custom_feed_worktree_dir)/luci-app-quickstart/luasrc/controller/istore_backend.lua"
    local makefile_path="$(get_custom_feed_worktree_dir)/quickstart/Makefile"
    local url="https://gist.githubusercontent.com/puteulanus/1c180fae6bccd25e57eb6d30b7aa28aa/raw/istore_backend.lua"
    if [ -f "$file_path" ]; then
        echo "正在修复 quickstart..."
        if ! curl_retry -fsSL -o "$file_path" "$url"; then
            echo "错误：从 $url 下载 istore_backend.lua 失败" >&2
            exit 1
        fi
    fi

    if [ -f "$makefile_path" ]; then
        echo "正在移除 quickstart 非必要存储依赖..."
        sed -i \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+smartmontools-drivedb//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+smartmontools//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+mdadm//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+parted//g' \
            -e '/^[[:space:]]*DEPENDS:=/,/^[[:space:]]*URL:=/ s/[[:space:]]*+e2fsprogs//g' \
            "$makefile_path"
    fi
}


update_oaf_deconfig() {
    local conf_path="$(get_custom_feed_worktree_dir)/open-app-filter/files/appfilter.config"
    local uci_def="$(get_custom_feed_worktree_dir)/luci-app-oaf/root/etc/uci-defaults/94_feature_3.0"
    local disable_path="$(get_custom_feed_worktree_dir)/luci-app-oaf/root/etc/uci-defaults/99_disable_oaf"

    if [ -d "${conf_path%/*}" ] && [ -f "$conf_path" ]; then
        sed -i \
            -e "s/record_enable '1'/record_enable '0'/g" \
            -e "s/disable_hnat '1'/disable_hnat '0'/g" \
            -e "s/auto_load_engine '1'/auto_load_engine '0'/g" \
            "$conf_path"
    fi

    if [ -d "${uci_def%/*}" ] && [ -f "$uci_def" ]; then
        sed -i '/\(disable_hnat\|auto_load_engine\)/d' "$uci_def"

        cat >"$disable_path" <<-EOF
#!/bin/sh
[ "\$(uci get appfilter.global.enable 2>/dev/null)" = "0" ] && {
    /etc/init.d/appfilter disable
    /etc/init.d/appfilter stop
}
EOF
        chmod +x "$disable_path"
    fi
}


fix_oaf_apk_acl_collision() {
    local custom_feed_dir
    local backend_makefile
    local backend_acl
    local frontend_acl
    local old_install_line
    local new_install_line
    local old_count
    local new_count
    local tmp_path
    local required_file

    custom_feed_dir=$(get_custom_feed_worktree_dir)
    backend_makefile="$custom_feed_dir/open-app-filter/Makefile"
    backend_acl="$custom_feed_dir/open-app-filter/files/luci-app-oaf.json"
    frontend_acl="$custom_feed_dir/luci-app-oaf/root/usr/share/rpcd/acl.d/luci-app-oaf.json"
    old_install_line=$'\t$(INSTALL_DATA) ./files/luci-app-oaf.json $(1)/usr/share/rpcd/acl.d/'
    new_install_line=$'\t$(INSTALL_DATA) ./files/luci-app-oaf.json $(1)/usr/share/rpcd/acl.d/appfilter.json'

    for required_file in "$backend_makefile" "$backend_acl" "$frontend_acl"; do
        if [[ ! -f $required_file || -L $required_file ]]; then
            echo "Error: required OAF source file is missing or is a symlink: $required_file" >&2
            return 1
        fi
    done
    old_count=$(grep -cFx "$old_install_line" "$backend_makefile" || true)
    new_count=$(grep -cFx "$new_install_line" "$backend_makefile" || true)
    if [[ $old_count -eq 1 && $new_count -eq 0 ]]; then
        tmp_path="$backend_makefile.tmp.$$"
        if ! awk -v from="$old_install_line" -v to="$new_install_line" \
            '{ if ($0 == from) print to; else print }' \
            "$backend_makefile" >"$tmp_path"; then
            rm -f "$tmp_path"
            return 1
        fi
        if ! chmod --reference="$backend_makefile" "$tmp_path" \
            || ! mv -f "$tmp_path" "$backend_makefile"; then
            rm -f "$tmp_path"
            return 1
        fi
    elif [[ $old_count -ne 0 || $new_count -ne 1 ]]; then
        echo "Error: unsupported OAF ACL install layout in $backend_makefile" >&2
        return 1
    fi

    if ! grep -qFx "$new_install_line" "$backend_makefile" \
        || grep -qFx "$old_install_line" "$backend_makefile"; then
        echo "Error: failed to assign the backend OAF ACL to appfilter.json" >&2
        return 1
    fi
}


fix_ddns_go_default_config() {
    local custom_feed_dir
    local config_source
    local makefile_path

    custom_feed_dir=$(get_custom_feed_worktree_dir)
    config_source="$custom_feed_dir/ddns-go/file/ddns-go.config"
    makefile_path="$custom_feed_dir/ddns-go/Makefile"

    if [ ! -f "$makefile_path" ]; then
        echo "Error: ddns-go Makefile not found: $makefile_path" >&2
        return 1
    fi

    install -Dm644 "$BASE_PATH/patches/ddns-go.config" "$config_source"

    if ! grep -qF '$(CURDIR)/file/ddns-go.config $(1)/etc/config/ddns-go' "$makefile_path"; then
        sed -i '/INSTALL_BIN.*ddns-go\.init.*ddns-go/a\
\
\t$(INSTALL_DIR) $(1)/etc/config\
\t$(INSTALL_CONF) $(CURDIR)/file/ddns-go.config $(1)/etc/config/ddns-go' "$makefile_path"
    fi

    if ! grep -qFx "config basic 'config'" "$config_source" \
        || ! grep -qF '$(INSTALL_CONF) $(CURDIR)/file/ddns-go.config $(1)/etc/config/ddns-go' "$makefile_path"; then
        echo "Error: failed to install the DDNS-Go default UCI configuration." >&2
        return 1
    fi
}


fix_easytier_mk() {
    local mk_path="$(get_custom_feed_worktree_dir)/luci-app-easytier/easytier/Makefile"
    if [ -f "$mk_path" ]; then
        sed -i 's/!@(mips||mipsel)/!TARGET_mips \&\& !TARGET_mipsel/g' "$mk_path"
    fi
}


remove_tweaked_packages() {
    local target_mk="$BUILD_DIR/include/target.mk"
    if [ -f "$target_mk" ]; then
        if grep -q "^DEFAULT_PACKAGES += \$(DEFAULT_PACKAGES.tweak)" "$target_mk"; then
            sed -i 's/DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/# DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/g' "$target_mk"
        fi
    fi
}
