#!/usr/bin/env bash
# Prepared-source identity used to prevent mislabeled cache resumes.

resolve_release_identity() {
    WRT_RELEASE_COMMIT=${WRT_RELEASE_COMMIT:-$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')}
    WRT_RELEASE_TREE_STATE=${WRT_RELEASE_TREE_STATE:-unknown}
    if [[ $WRT_RELEASE_TREE_STATE == "unknown" ]] && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        if [[ -n $(git -C "$REPO_ROOT" status --porcelain -- build.sh wrt_core) ]]; then
            WRT_RELEASE_TREE_STATE=dirty
        else
            WRT_RELEASE_TREE_STATE=clean
        fi
    fi

    WRT_RELEASE_INPUT_SHA256=${WRT_RELEASE_INPUT_SHA256:-unknown}
    if [[ $WRT_RELEASE_INPUT_SHA256 == "unknown" ]]; then
        WRT_RELEASE_INPUT_SHA256=$(
            cd "$REPO_ROOT"
            {
                [[ -f .gitattributes ]] && printf '%s\0' .gitattributes
                printf '%s\0' build.sh
                find wrt_core -type f -print0
            } | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
        )
    fi

    SOURCE_LOCKS_SHA256=$(sha256sum "$BASE_PATH/source-locks.env" | awk '{print $1}')
    BUILD_CONTAINER_BASE=$(read_ini_by_key "BUILD_TARGET_SDK")
    CURRENT_CONTAINER_IMAGE_ID=${BUILD_CONTAINER_IMAGE_ID:-native}
    BUILD_CONTAINER_IMAGE_REF=${BUILD_CONTAINER_IMAGE_REF:-not-applicable}
    BUILD_CONTAINER_MANIFEST_DIGEST=${BUILD_CONTAINER_MANIFEST_DIGEST:-not-applicable}

    if [[ $BUILD_CONTAINER_IMAGE_REF == not-applicable \
        && $BUILD_CONTAINER_MANIFEST_DIGEST == not-applicable ]]; then
        return 0
    fi
    if [[ ! $BUILD_CONTAINER_IMAGE_REF =~ @sha256:[0-9a-f]{64}$ ]] \
        || [[ ! $BUILD_CONTAINER_MANIFEST_DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] \
        || [[ ${BUILD_CONTAINER_IMAGE_REF##*@} != "$BUILD_CONTAINER_MANIFEST_DIGEST" ]]; then
        echo "Error: audited builder reference and manifest digest must be matching immutable OCI values." >&2
        return 1
    fi
}

build_state_value() {
    local state_file="$1"
    local key="$2"
    awk -F': ' -v key="$key" '$1 == key { sub(/^[^:]+: /, ""); print; exit }' "$state_file"
}

compute_prepared_source_sha256() {
    local source_dir="$1"
    local entry
    local find_record
    local relative_path
    local content_sha256
    local file_mode

    (
        cd "$source_dir"
        while IFS= read -r -d '' find_record; do
            file_mode=${find_record%% *}
            entry=${find_record#* }
            relative_path=${entry#./}
            if [[ -L "$entry" ]]; then
                printf 'L\0%s\0%s\0%s\0' "$relative_path" "$file_mode" "$(readlink "$entry")"
            else
                content_sha256=$(sha256sum "$entry" | awk '{print $1}')
                printf 'F\0%s\0%s\0%s\0' "$relative_path" "$file_mode" "$content_sha256"
            fi
        done < <(
            find . \
                \( -type d \( \
                    -name .git -o -path './feeds/*.tmp' -o \
                    -path ./build_dir -o -path ./staging_dir -o \
                    -path ./dl -o -path ./bin -o -path ./tmp -o -path ./logs -o \
                    -path ./.ccache \
                \) -prune \) -o \
                \( \( -type f -o -type l \) \
                    ! -path './.config' \
                    ! -path './.config.old' \
                    ! -path './key-build*' \
                    ! -path './feeds/luci/modules/luci-base/src/contrib/lemon' \
                    ! -path './feeds/luci/modules/luci-base/src/jsmin' \
                    ! -path './feeds/luci/modules/luci-base/src/po2lmo' \
                    ! -path './feeds/luci/modules/luci-base/src/lib/plural_formula.c' \
                    ! -path './feeds/luci/modules/luci-base/src/lib/plural_formula.h' \
                    ! -path './feeds/luci/modules/luci-base/src/jsmin.o' \
                    ! -path './feeds/luci/modules/luci-base/src/lib/lmo.o' \
                    ! -path './feeds/luci/modules/luci-base/src/lib/plural_formula.o' \
                    ! -path './feeds/luci/modules/luci-base/src/po2lmo.o' \
                    ! -path './scripts/config/conf.o' \
                    ! -path './scripts/config/confdata.o' \
                    ! -path './scripts/config/expr.o' \
                    ! -path './scripts/config/lexer.lex.o' \
                    ! -path './scripts/config/menu.o' \
                    ! -path './scripts/config/parser.tab.o' \
                    ! -path './scripts/config/preprocess.o' \
                    ! -path './scripts/config/symbol.o' \
                    ! -path './scripts/config/util.o' \
                    ! -name '.wrt-release-build-state' \
                    -printf '%m %p\0' \
                \) | LC_ALL=C sort -z -k2
        )
    ) | sha256sum | awk '{print $1}'
}

apk_build_public_key_sha256() {
    local source_dir="$1"

    if ! grep -qFx 'CONFIG_USE_APK=y' "$source_dir/.config"; then
        printf '%s\n' not-applicable
        return 0
    fi
    if [[ ! -f $source_dir/public-key.pem || -L $source_dir/public-key.pem ]]; then
        echo "Error: APK build public key is missing or is not a regular file." >&2
        return 1
    fi

    sha256sum "$source_dir/public-key.pem" | awk '{print $1}'
}

validate_apk_build_key_pair() (
    set -euo pipefail

    local source_dir="$1"
    local openssl_bin
    local derived_public_key
    local private_mode

    if ! grep -qFx 'CONFIG_USE_APK=y' "$source_dir/.config"; then
        return 0
    fi
    if [[ ! -f $source_dir/private-key.pem || -L $source_dir/private-key.pem ]]; then
        echo "Error: APK build private key is missing or is not a regular file." >&2
        return 1
    fi
    if [[ ! -f $source_dir/public-key.pem || -L $source_dir/public-key.pem ]]; then
        echo "Error: APK build public key is missing or is not a regular file." >&2
        return 1
    fi
    private_mode=$(stat -c '%a' "$source_dir/private-key.pem")
    if [[ $private_mode != 600 ]]; then
        echo "Error: APK build private key mode must be 600, got $private_mode." >&2
        return 1
    fi
    openssl_bin=$(command -v openssl || true)
    if [[ -z $openssl_bin ]]; then
        echo "Error: openssl is required to validate the APK build key pair." >&2
        return 1
    fi
    derived_public_key=$(mktemp)
    trap 'rm -f "$derived_public_key"' EXIT INT TERM
    if ! "$openssl_bin" ec -in "$source_dir/private-key.pem" \
        -pubout -out "$derived_public_key" >/dev/null 2>&1; then
        echo "Error: unable to derive the APK public key from the private key." >&2
        return 1
    fi
    if ! cmp -s "$derived_public_key" "$source_dir/public-key.pem"; then
        echo "Error: APK build private and public keys do not form a pair." >&2
        return 1
    fi
)

prepare_apk_build_keys() (
    set -euo pipefail

    local source_dir="$1"
    local openssl_bin
    local private_tmp
    local public_tmp

    if ! grep -qFx 'CONFIG_USE_APK=y' "$source_dir/.config"; then
        return 0
    fi
    if [[ -L $source_dir/private-key.pem || -L $source_dir/public-key.pem ]]; then
        echo "Error: APK build keys must not be symbolic links." >&2
        return 1
    fi
    if [[ -e $source_dir/private-key.pem || -e $source_dir/public-key.pem ]]; then
        if [[ ! -f $source_dir/private-key.pem || ! -f $source_dir/public-key.pem ]]; then
            echo "Error: incomplete APK build key pair in $source_dir." >&2
            return 1
        fi
    else
        openssl_bin=$(command -v openssl || true)
        if [[ -z $openssl_bin ]]; then
            echo "Error: openssl is required to generate APK build keys." >&2
            return 1
        fi
        private_tmp="$source_dir/.private-key.pem.$$"
        public_tmp="$source_dir/.public-key.pem.$$"
        trap 'rm -f "$private_tmp" "$public_tmp"' EXIT INT TERM
        umask 077
        "$openssl_bin" ecparam -name prime256v1 -genkey -noout -out "$private_tmp"
        "$openssl_bin" ec -in "$private_tmp" -pubout -out "$public_tmp" >/dev/null 2>&1
        chmod 0600 "$private_tmp"
        chmod 0644 "$public_tmp"
        mv -f "$private_tmp" "$source_dir/private-key.pem"
        mv -f "$public_tmp" "$source_dir/public-key.pem"
    fi

    validate_apk_build_key_pair "$source_dir"
)

write_build_state() {
    local source_dir="$1"
    local state_file="$source_dir/.wrt-release-build-state"
    local config_sha256
    local prepared_source_sha256
    local apk_build_public_key_sha256
    local build_container_image_ref
    local build_container_manifest_digest
    local taiyi_plugin_feed_catalog_sha256
    local taiyi_plugin_feed_allowlist_sha256
    local taiyi_plugin_feed_policy_version_sha256
    local taiyi_plugin_feed_index_url
    local taiyi_plugin_feed_public_key_sha256

    config_sha256=$(sha256sum "$source_dir/.config" | awk '{print $1}')
    taiyi_plugin_feed_load_config || return 1
    taiyi_plugin_feed_catalog_sha256=$(taiyi_plugin_feed_catalog_sha256)
    taiyi_plugin_feed_allowlist_sha256=$(taiyi_plugin_feed_allowlist_sha256)
    taiyi_plugin_feed_policy_version_sha256=$(taiyi_plugin_feed_policy_version_sha256)
    taiyi_plugin_feed_index_url=${TAIYI_PLUGIN_FEED_INDEX_URL:-not-enabled}
    taiyi_plugin_feed_public_key_sha256=${TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256:-not-enabled}
    validate_apk_build_key_pair "$source_dir"
    apk_build_public_key_sha256=$(apk_build_public_key_sha256 "$source_dir")
    build_container_image_ref=${BUILD_CONTAINER_IMAGE_REF:-not-applicable}
    build_container_manifest_digest=${BUILD_CONTAINER_MANIFEST_DIGEST:-not-applicable}
    prepared_source_sha256=$(compute_prepared_source_sha256 "$source_dir")
    cat >"$state_file" <<EOF
Device: $Dev
WrtReleaseCommit: $WRT_RELEASE_COMMIT
WrtReleaseTreeState: $WRT_RELEASE_TREE_STATE
WrtReleaseInputSha256: $WRT_RELEASE_INPUT_SHA256
SourceLocksSha256: $SOURCE_LOCKS_SHA256
SourceCommit: $COMMIT_HASH
ConfigFragments: $(join_fragments "${EFFECTIVE_CONFIG_FRAGMENTS[@]}")
ConfigSha256: $config_sha256
PreparedSourceSha256: $prepared_source_sha256
ApkBuildPublicKeySha256: $apk_build_public_key_sha256
TaiyiPluginFeedMode: $TAIYI_PLUGIN_FEED_MODE
TaiyiPluginFeedIndexUrl: $taiyi_plugin_feed_index_url
TaiyiPluginFeedPublicKeySha256: $taiyi_plugin_feed_public_key_sha256
TaiyiPluginFeedCatalogSha256: $taiyi_plugin_feed_catalog_sha256
TaiyiPluginFeedAllowlistSha256: $taiyi_plugin_feed_allowlist_sha256
TaiyiPluginPolicyVersionSha256: $taiyi_plugin_feed_policy_version_sha256
BuildContainerBase: $BUILD_CONTAINER_BASE
BuildContainerImageRef: $build_container_image_ref
BuildContainerManifestDigest: $build_container_manifest_digest
BuildContainerImageId: $CURRENT_CONTAINER_IMAGE_ID
EOF
}

assert_build_state_value() {
    local state_file="$1"
    local key="$2"
    local expected="$3"
    local actual

    actual=$(build_state_value "$state_file" "$key")
    if [[ "$actual" != "$expected" ]]; then
        echo "Error: resume build-state mismatch for $key: expected '$expected', got '$actual'." >&2
        return 1
    fi
}

validate_build_state() {
    local source_dir="$1"
    local state_file="$source_dir/.wrt-release-build-state"
    local config_sha256
    local source_commit
    local prepared_source_sha256
    local apk_build_public_key_sha256
    local taiyi_plugin_feed_catalog_sha256
    local taiyi_plugin_feed_allowlist_sha256
    local taiyi_plugin_feed_policy_version_sha256
    local taiyi_plugin_feed_index_url
    local taiyi_plugin_feed_public_key_sha256

    if [[ ! -f "$state_file" ]]; then
        echo "Error: resume requires prepared build state: $state_file" >&2
        return 1
    fi

    config_sha256=$(sha256sum "$source_dir/.config" | awk '{print $1}')
    source_commit=$(git -C "$source_dir" rev-parse HEAD)
    validate_apk_build_key_pair "$source_dir"
    apk_build_public_key_sha256=$(apk_build_public_key_sha256 "$source_dir")
    taiyi_plugin_feed_load_config || return 1
    taiyi_plugin_feed_catalog_sha256=$(taiyi_plugin_feed_catalog_sha256)
    taiyi_plugin_feed_allowlist_sha256=$(taiyi_plugin_feed_allowlist_sha256)
    taiyi_plugin_feed_policy_version_sha256=$(taiyi_plugin_feed_policy_version_sha256)
    taiyi_plugin_feed_index_url=${TAIYI_PLUGIN_FEED_INDEX_URL:-not-enabled}
    taiyi_plugin_feed_public_key_sha256=${TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256:-not-enabled}
    prepared_source_sha256=$(compute_prepared_source_sha256 "$source_dir")
    assert_build_state_value "$state_file" "Device" "$Dev" || return 1
    assert_build_state_value "$state_file" "WrtReleaseCommit" "$WRT_RELEASE_COMMIT" || return 1
    assert_build_state_value "$state_file" "WrtReleaseTreeState" "$WRT_RELEASE_TREE_STATE" || return 1
    assert_build_state_value "$state_file" "WrtReleaseInputSha256" "$WRT_RELEASE_INPUT_SHA256" || return 1
    assert_build_state_value "$state_file" "SourceLocksSha256" "$SOURCE_LOCKS_SHA256" || return 1
    assert_build_state_value "$state_file" "SourceCommit" "$source_commit" || return 1
    assert_build_state_value "$state_file" "ConfigFragments" "$(join_fragments "${EFFECTIVE_CONFIG_FRAGMENTS[@]}")" || return 1
    assert_build_state_value "$state_file" "ConfigSha256" "$config_sha256" || return 1
    assert_build_state_value "$state_file" "PreparedSourceSha256" "$prepared_source_sha256" || return 1
    assert_build_state_value "$state_file" "ApkBuildPublicKeySha256" "$apk_build_public_key_sha256" || return 1
    assert_build_state_value "$state_file" "TaiyiPluginFeedMode" "$TAIYI_PLUGIN_FEED_MODE" || return 1
    assert_build_state_value "$state_file" "TaiyiPluginFeedIndexUrl" "$taiyi_plugin_feed_index_url" || return 1
    assert_build_state_value "$state_file" "TaiyiPluginFeedPublicKeySha256" "$taiyi_plugin_feed_public_key_sha256" || return 1
    assert_build_state_value "$state_file" "TaiyiPluginFeedCatalogSha256" "$taiyi_plugin_feed_catalog_sha256" || return 1
    assert_build_state_value "$state_file" "TaiyiPluginFeedAllowlistSha256" "$taiyi_plugin_feed_allowlist_sha256" || return 1
    assert_build_state_value "$state_file" "TaiyiPluginPolicyVersionSha256" "$taiyi_plugin_feed_policy_version_sha256" || return 1
    assert_build_state_value "$state_file" "BuildContainerBase" "$BUILD_CONTAINER_BASE" || return 1
    assert_build_state_value "$state_file" "BuildContainerImageRef" "${BUILD_CONTAINER_IMAGE_REF:-not-applicable}" || return 1
    assert_build_state_value "$state_file" "BuildContainerManifestDigest" "${BUILD_CONTAINER_MANIFEST_DIGEST:-not-applicable}" || return 1
    assert_build_state_value "$state_file" "BuildContainerImageId" "$CURRENT_CONTAINER_IMAGE_ID" || return 1
}
