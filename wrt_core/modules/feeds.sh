#!/usr/bin/env bash

get_feeds_path() {
    local feeds_path="$BUILD_DIR/$FEEDS_CONF"
    if [[ -f "$BUILD_DIR/feeds.conf" ]]; then
        feeds_path="$BUILD_DIR/feeds.conf"
    fi
    printf '%s\n' "$feeds_path"
}

set_pinned_feed() {
    local feeds_path="$1"
    local feed_name="$2"
    local feed_url="$3"
    local feed_commit="$4"

    sed -i "/^src-git[[:space:]]\+$feed_name[[:space:]]/d" "$feeds_path"
    [ -z "$(tail -c 1 "$feeds_path")" ] || echo "" >>"$feeds_path"
    printf 'src-git %s %s^%s\n' "$feed_name" "$feed_url" "$feed_commit" >>"$feeds_path"
}

update_feeds() {
    local FEEDS_PATH
    FEEDS_PATH=$(get_feeds_path)
    sed -i '/^#/d' "$FEEDS_PATH"
    sed -i '/packages_ext/d' "$FEEDS_PATH"
    sed -i '/[[:space:]]small8[[:space:]]/d' "$FEEDS_PATH"
    sed -i '/[[:space:]]custom_feed[[:space:]]/d' "$FEEDS_PATH"

    set_pinned_feed "$FEEDS_PATH" "nss_packages" "https://github.com/qosmio/nss-packages.git" "$NSS_PACKAGES_FEED_COMMIT"
    set_pinned_feed "$FEEDS_PATH" "sqm_scripts_nss" "https://github.com/qosmio/sqm-scripts-nss.git" "$SQM_SCRIPTS_NSS_FEED_COMMIT"
    set_pinned_feed "$FEEDS_PATH" "openwrt_bandix" "https://github.com/timsaya/openwrt-bandix.git" "$OPENWRT_BANDIX_FEED_COMMIT"
    set_pinned_feed "$FEEDS_PATH" "luci_app_bandix" "https://github.com/timsaya/luci-app-bandix.git" "$LUCI_APP_BANDIX_FEED_COMMIT"

    if [ ! -f "$BUILD_DIR/include/bpf.mk" ]; then
        touch "$BUILD_DIR/include/bpf.mk"
    fi

    network_retry ./scripts/feeds update -a
}

install_feeds() {
    network_retry ./scripts/feeds update -i
    ./scripts/feeds install -a -f
}
