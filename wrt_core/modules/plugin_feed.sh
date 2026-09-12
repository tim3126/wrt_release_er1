#!/usr/bin/env bash
# Non-secret configuration and rootfs injection for the Taiyi add-on APK feed.

_taiyi_plugin_feed_dir() {
    printf '%s\n' "$BASE_PATH/taiyi-plugin-feed"
}

taiyi_plugin_feed_load_config() {
    local config_file
    local line
    local key
    local value
    local url_seen=0
    local fingerprint_seen=0

    config_file="$(_taiyi_plugin_feed_dir)/channel.env"
    if [[ ! -f $config_file || -L $config_file ]]; then
        echo "Error: Taiyi plugin feed configuration is missing or is a symbolic link: $config_file" >&2
        return 1
    fi

    TAIYI_PLUGIN_FEED_INDEX_URL=
    TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256=
    TAIYI_PLUGIN_FEED_MODE=disabled

    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == \#* ]] && continue
        [[ $line == *=* ]] || {
            echo "Error: invalid Taiyi plugin feed configuration line." >&2
            return 1
        }
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            TAIYI_PLUGIN_FEED_INDEX_URL)
                ((url_seen += 1))
                TAIYI_PLUGIN_FEED_INDEX_URL=$value
                ;;
            TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256)
                ((fingerprint_seen += 1))
                TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256=$value
                ;;
            *)
                echo "Error: unknown Taiyi plugin feed configuration key: $key" >&2
                return 1
                ;;
        esac
    done <"$config_file"

    if ((url_seen != 1 || fingerprint_seen != 1)); then
        echo "Error: Taiyi plugin feed configuration requires each supported key exactly once." >&2
        return 1
    fi

    if [[ -z $TAIYI_PLUGIN_FEED_INDEX_URL && -z $TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256 ]]; then
        return 0
    fi
    if [[ -z $TAIYI_PLUGIN_FEED_INDEX_URL || -z $TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256 ]]; then
        echo "Error: Taiyi plugin feed URL and public-key fingerprint must be configured together." >&2
        return 1
    fi
    if [[ ! $TAIYI_PLUGIN_FEED_INDEX_URL =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*/[A-Za-z0-9._~/%+:-]*/packages\.adb$ ]] \
        || [[ $TAIYI_PLUGIN_FEED_INDEX_URL == *..* ]]; then
        echo "Error: Taiyi plugin feed index URL must be a stable HTTPS packages.adb path without traversal." >&2
        return 1
    fi
    if [[ ! $TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256 =~ ^[0-9a-f]{64}$ ]]; then
        echo "Error: Taiyi plugin feed public-key fingerprint must be a lowercase SHA-256 digest." >&2
        return 1
    fi

    local public_key
    local actual_fingerprint
    local openssl_bin
    public_key="$(_taiyi_plugin_feed_dir)/public-key.pem"
    if [[ ! -f $public_key || -L $public_key ]]; then
        echo "Error: enabled Taiyi plugin feed requires a regular public key: $public_key" >&2
        return 1
    fi
    actual_fingerprint=$(sha256sum "$public_key" | awk '{print $1}')
    if [[ $actual_fingerprint != "$TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256" ]]; then
        echo "Error: Taiyi plugin feed public-key fingerprint does not match channel.env." >&2
        return 1
    fi
    openssl_bin=$(command -v openssl || true)
    if [[ -z $openssl_bin ]] \
        || ! "$openssl_bin" ec -pubin -in "$public_key" -noout >/dev/null 2>&1; then
        echo "Error: Taiyi plugin feed public key is not a valid EC public key." >&2
        return 1
    fi

    TAIYI_PLUGIN_FEED_MODE=enabled
}

taiyi_plugin_feed_catalog_sha256() {
    sha256sum "$BASE_PATH/patches/taiyi-apk-plugin-catalog" | awk '{print $1}'
}

taiyi_plugin_feed_allowlist_sha256() {
    sha256sum "$(_taiyi_plugin_feed_dir)/allowlist" | awk '{print $1}'
}

taiyi_plugin_feed_policy_version_sha256() {
    sha256sum "$BASE_PATH/patches/taiyi-apk-plugin-policy-version" | awk '{print $1}'
}

install_taiyi_plugin_feed_rootfs() {
    local rootfs_dir=$1
    local plugin_feed_dir

    taiyi_plugin_feed_load_config || return 1
    plugin_feed_dir="$(_taiyi_plugin_feed_dir)"

    rm -f "$rootfs_dir/etc/apk/keys/taiyi-plugin-feed.pem" \
        "$rootfs_dir/usr/share/taiyi/apk-plugin-feed"
    if [[ $TAIYI_PLUGIN_FEED_MODE == disabled ]]; then
        return 0
    fi

    install -Dm644 "$plugin_feed_dir/public-key.pem" \
        "$rootfs_dir/etc/apk/keys/taiyi-plugin-feed.pem"
    install -d -m 0755 "$rootfs_dir/usr/share/taiyi"
    printf '%s\n' "$TAIYI_PLUGIN_FEED_INDEX_URL" \
        >"$rootfs_dir/usr/share/taiyi/apk-plugin-feed"
    chmod 0644 "$rootfs_dir/usr/share/taiyi/apk-plugin-feed"
}
