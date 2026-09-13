#!/usr/bin/env bash

set -e
set -o errexit
set -o errtrace

error_handler() {
    echo "Error occurred in script at line: ${BASH_LINENO[0]}, command: '${BASH_COMMAND}'"
}

trap 'error_handler' ERR

REPO_URL=$1
REPO_BRANCH=$2
BUILD_DIR=$3
COMMIT_HASH=$4

# 转换为绝对路径，避免后续 cd 后路径失效。
if [[ "$BUILD_DIR" != /* ]]; then
    BUILD_DIR="$(pwd)/$BUILD_DIR"
fi

FEEDS_CONF="feeds.conf.default"
GOLANG_REPO="https://github.com/sbwml/packages_lang_golang"
GOLANG_BRANCH="26.x"
THEME_SET=${5:-argon}
CUSTOM_FEED_EXCLUDES=${6:-}
BUILD_PROFILE=${7:-}
LAN_ADDR="192.168.10.1"

is_er1_profile() {
    [[ $BUILD_PROFILE == "jdcloud_er1_libwrt" ]]
}

SCRIPT_DIR=$(cd $(dirname $0) && pwd)
BASE_PATH=${BASE_PATH:-$SCRIPT_DIR}
SOURCE_LOCKS_FILE="$SCRIPT_DIR/source-locks.env"
if [[ ! -f "$SOURCE_LOCKS_FILE" ]]; then
    echo "错误：缺少源码锁文件 $SOURCE_LOCKS_FILE" >&2
    exit 1
fi
# shellcheck source=source-locks.env
source "$SOURCE_LOCKS_FILE"

validate_source_locks() {
    local variable_name
    local variable_value
    local variables=(
        NSS_PACKAGES_FEED_COMMIT SQM_SCRIPTS_NSS_FEED_COMMIT
        OPENWRT_BANDIX_FEED_COMMIT LUCI_APP_BANDIX_FEED_COMMIT
        SMALL_PACKAGE_COMMIT NIKKI_COMMIT EMMC_HEALTH_COMMIT OAF_COMMIT HOMEPROXY_COMMIT
        GOLANG_COMMIT LUCKY_COMMIT DISKMAN_COMMIT LUCI_LIB_DOCKER_COMMIT
        DOCKERMAN_COMMIT ADGUARDHOME_LUCI_COMMIT PASSWALL_PACKAGES_COMMIT
    )
    local sha256_variables=(
        EASYTIER_AARCH64_RELEASE_SHA256 CUPS_SOURCE_SHA256
        GEOIP_SOURCE_SHA256 GEOIP_CN_PRIVATE_SHA256
    )

    for variable_name in "${variables[@]}"; do
        variable_value=${!variable_name:-}
        if [[ ! $variable_value =~ ^[0-9a-f]{40}$ ]]; then
            echo "错误：$SOURCE_LOCKS_FILE 中的 $variable_name 必须是 40 位小写 Git SHA" >&2
            exit 1
        fi
    done

    for variable_name in "${sha256_variables[@]}"; do
        variable_value=${!variable_name:-}
        if [[ ! $variable_value =~ ^[0-9a-f]{64}$ ]]; then
            echo "错误：$SOURCE_LOCKS_FILE 中的 $variable_name 必须是 64 位小写 SHA-256" >&2
            exit 1
        fi
    done

    if [[ ! $GEOIP_LOCKED_VERSION =~ ^[0-9]{12}$ ]]; then
        echo "错误：$SOURCE_LOCKS_FILE 中的 GEOIP_LOCKED_VERSION 必须是 12 位版本号" >&2
        exit 1
    fi
}

validate_source_locks

# 按静态职责加载模块，执行顺序仍由本脚本统一控制。
source "$SCRIPT_DIR/modules/network.sh"
source "$SCRIPT_DIR/modules/repo.sh"
source "$SCRIPT_DIR/modules/feeds.sh"
source "$SCRIPT_DIR/modules/custom_feed.sh"
source "$SCRIPT_DIR/modules/plugin_feed.sh"
source "$SCRIPT_DIR/modules/verify.sh"
source "$SCRIPT_DIR/modules/docker.sh"
source "$SCRIPT_DIR/modules/cups.sh"
source "$SCRIPT_DIR/modules/feed_source_fixes.sh"
source "$SCRIPT_DIR/modules/package_source_updates.sh"
source "$SCRIPT_DIR/modules/target_fixes.sh"
source "$SCRIPT_DIR/modules/luci_fixes.sh"
source "$SCRIPT_DIR/modules/service_fixes.sh"


# 阶段顺序不可随意调整：feeds install 前后依赖的目录不同。
stage_repo_checkout() {
    # 从干净的上游源码树开始，保证后续修正基线一致。
    clone_repo
    clean_up
    reset_feeds_conf
}

stage_upstream_feeds_update() {
    # 先生成上游 feeds/* 工作树。
    update_feeds
}

stage_feed_source_cleanup() {
    # 清理会与 custom_feed 替换包冲突的上游 feed 包。
    remove_unwanted_packages
    remove_tweaked_packages
}

stage_custom_feed_prepare() {
    # custom_feed 以 src-link 加入 feeds，仍属于 install 前阶段。
    install_custom_feed
}

stage_pre_install_source_fixes() {
    # 这里仅修改源码树与 feeds/*，不能依赖 package/feeds/*。
    update_homeproxy
    fix_default_set
    fix_miniupnpd
    update_golang
    change_dnsmasq2full
    fix_mk_def_depends

    update_default_lan_addr
    remove_something_nss_kmod
    update_affinity_script
    if ! is_er1_profile; then
        update_ath11k_fw
    fi
    change_cpuusage
    update_tcping
    if ! is_er1_profile; then
        add_ax6600_led
    fi
    set_custom_task
    if ! is_er1_profile; then
        update_nss_pbuf_performance
    fi
    set_build_signature
    if ! is_er1_profile; then
        update_nss_diag
    fi
    update_menu_location
    fix_compile_coremark
    update_dnsmasq_conf
    add_backup_info_to_sysupgrade
    if ! is_er1_profile; then
        fix_quickstart
    fi
    update_oaf_deconfig
    if is_er1_profile; then
        fix_oaf_apk_acl_collision
    fi
    fix_ddns_go_default_config
    if is_er1_profile; then
        fix_er1_frpc_default_disabled
    fi
    if ! is_er1_profile; then
        add_timecontrol
        add_quickfile
    fi
    update_lucky
    fix_rust_compile_error
    if ! is_er1_profile; then
        update_smartdns
        update_mwan3_fw4
    fi
    update_diskman
    update_dockerman
    if is_er1_profile; then
        fix_luci_docker_apk_versions
    fi
    if ! is_er1_profile; then
        set_nginx_default_config
        update_uwsgi_limit_as
    fi
    if [ "$THEME_SET" = "argon" ]; then
        update_argon
    fi
    update_nginx_ubus_module
    if is_er1_profile; then
        if [[ ! -d "$BUILD_DIR/package/emortal/default-settings" ]]; then
            echo "错误：ER1 固定 LibWrt 源码缺少 package/emortal/default-settings" >&2
            return 1
        fi
    else
        check_default_settings
    fi
    if ! is_er1_profile; then
        install_opkg_distfeeds
    fi
    fix_easytier_mk
    remove_attendedsysupgrade
    fix_kconfig_recursive_dependency
}

stage_feeds_install() {
    # install 后才会生成 package/feeds/*。
    install_feeds
}

stage_post_install_package_fixes() {
    # 这里处理已安装到 package/feeds/* 的包和最终一致性检查。
    verify_custom_feed_installed_paths
    docker_stack_sync_nftables_compat "$BUILD_DIR" "0"
    fix_cups_libcups_avahi_depends
    fix_easytier_lua
    update_adguardhome
    update_script_priority
    update_geoip
    fix_openssl_ktls
    if is_er1_profile; then
        restrict_er1_luci_apk_upgrade
        fix_er1_luci_apk_dependency_rendering
    else
        fix_opkg_check
    fi
    fix_netfilter_kmod_clash
    if ! is_er1_profile; then
        fix_quectel_cm
    fi
    install_pbr_cmcc
    fix_pbr_ip_forward
    # apply_hash_fixes
}

main() {
    stage_repo_checkout
    stage_upstream_feeds_update
    stage_feed_source_cleanup
    stage_custom_feed_prepare
    stage_pre_install_source_fixes
    stage_feeds_install
    stage_post_install_package_fixes
}

main "$@"
