#!/usr/bin/env bash
# Stages a whitelist of built APKs and signs a minimal Taiyi add-on feed index.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  publish-plugin-feed.sh stage --source DIR --packages DIR --catalog FILE --allowlist FILE --policy-version FILE --firmware-provenance FILE --output DIR
  publish-plugin-feed.sh sign --candidate DIR --output DIR --apk FILE --private-key FILE --public-key FILE --index-url URL

stage requires ALLOW_TAIYI_PLUGIN_FEED_STAGE=1. sign requires
ALLOW_TAIYI_PLUGIN_FEED_SIGN=1. Both output directories must not already exist.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_absolute_dir() {
    local path=$1
    [[ $path == /* && -d $path && ! -L $path ]] || fail "expected a regular absolute directory: $path"
}

require_absolute_file() {
    local path=$1
    [[ $path == /* && -f $path && ! -L $path ]] || fail "expected a regular absolute file: $path"
}

is_platform_package() {
    case "$1" in
        apk|apk-*|base-files|busybox|kernel|kernel-*|kmod-*|nss-*|*nss*|*ecm*|\
        libc|musl|libgcc|libstdcpp*|libubox*|libubus*|libuci*|\
        procd|procd-*|ubox|ubus|ubus-*|uci|uci-*|rpcd|rpcd-*|\
        dropbear|dropbear-*|uhttpd|uhttpd-*|luci-base|luci-lib-*|luci-mod-*|\
        firewall4|fw4|nftables*|netifd|netifd-*|dnsmasq|dnsmasq-*|\
        ppp|ppp-*|odhcp*|ip-full|ip-tiny|iproute2*|tc*)
            return 0
            ;;
    esac
    return 1
}

catalog_class() {
    awk -v package_name="$1" '$1 !~ /^#/ && $2 == package_name { print $1; exit }' "$2"
}

read_allowlist() {
    local allowlist=$1
    local catalog=$2
    local line
    local package_name
    local class
    local -A seen=()

    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == \#* ]] && continue
        package_name=$line
        [[ $package_name =~ ^[A-Za-z0-9][A-Za-z0-9+_.-]*$ ]] \
            || fail "invalid add-on feed allowlist package: $package_name"
        [[ -z ${seen[$package_name]+x} ]] \
            || fail "duplicate add-on feed allowlist package: $package_name"
        is_platform_package "$package_name" \
            && fail "platform package cannot enter the add-on feed: $package_name"
        seen[$package_name]=1
        class=$(catalog_class "$package_name" "$catalog")
        case "$class" in
            safe|network-critical)
                printf '%s\n' "$package_name"
                ;;
            firmware-only)
                fail "firmware-only package cannot enter the add-on feed: $package_name"
                ;;
            *)
                fail "allowlist package is absent from the Taiyi runtime catalog: $package_name"
                ;;
        esac
    done <"$allowlist"
}

stage() {
    local source_dir=
    local packages_dir=
    local catalog=
    local allowlist=
    local policy_version=
    local firmware_provenance=
    local output=
    local package_name
    local provenance_key
    local provenance_value
    local matches
    local package_path
    local -a packages=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source) source_dir=$2; shift 2 ;;
            --packages) packages_dir=$2; shift 2 ;;
            --catalog) catalog=$2; shift 2 ;;
            --allowlist) allowlist=$2; shift 2 ;;
            --policy-version) policy_version=$2; shift 2 ;;
            --firmware-provenance) firmware_provenance=$2; shift 2 ;;
            --output) output=$2; shift 2 ;;
            *) fail "unknown stage option: $1" ;;
        esac
    done

    [[ ${ALLOW_TAIYI_PLUGIN_FEED_STAGE:-} == 1 ]] \
        || fail 'stage requires ALLOW_TAIYI_PLUGIN_FEED_STAGE=1'
    require_absolute_dir "$source_dir"
    require_absolute_dir "$packages_dir"
    require_absolute_file "$catalog"
    require_absolute_file "$allowlist"
    require_absolute_file "$policy_version"
    require_absolute_file "$firmware_provenance"
    [[ -f $source_dir/.wrt-release-build-state && ! -L $source_dir/.wrt-release-build-state ]] \
        || fail 'source build state is missing or unsafe'
    [[ $output == /* && ! -e $output ]] || fail "stage output must be an absent absolute path: $output"
    grep -qFx 'TaiyiPluginFeedMode: enabled' "$firmware_provenance" \
        || fail 'firmware provenance does not bind an enabled Taiyi plugin feed'
    grep -qFx 'WrtReleaseTreeState: clean' "$firmware_provenance" \
        || fail 'firmware provenance is not a clean-tree build'
    grep -qFx "TaiyiPluginFeedCatalogSha256: $(sha256sum "$catalog" | awk '{print $1}')" "$firmware_provenance" \
        || fail 'firmware provenance does not bind the staged catalog'
    grep -qFx "TaiyiPluginFeedAllowlistSha256: $(sha256sum "$allowlist" | awk '{print $1}')" "$firmware_provenance" \
        || fail 'firmware provenance does not bind the staged allowlist'
    grep -qFx "TaiyiPluginPolicyVersionSha256: $(sha256sum "$policy_version" | awk '{print $1}')" "$firmware_provenance" \
        || fail 'firmware provenance does not bind the staged policy version'
    for provenance_key in WrtReleaseCommit SourceCommit PreparedSourceSha256 ConfigSha256; do
        provenance_value=$(awk -F': ' -v key="$provenance_key" '$1 == key { print $2; exit }' "$source_dir/.wrt-release-build-state")
        [[ -n $provenance_value ]] \
            && grep -qFx "$provenance_key: $provenance_value" "$firmware_provenance" \
            || fail "source build state and firmware provenance differ for $provenance_key"
    done

    mapfile -t packages < <(read_allowlist "$allowlist" "$catalog")
    (( ${#packages[@]} > 0 )) || fail 'add-on feed allowlist is empty'
    mkdir -p "$output/packages"

    for package_name in "${packages[@]}"; do
        mapfile -d '' -t matches < <(find "$packages_dir" -type f -name "$package_name-*.apk" -print0 | LC_ALL=C sort -z)
        (( ${#matches[@]} == 1 )) \
            || fail "expected exactly one built APK for $package_name, found ${#matches[@]}"
        package_path=${matches[0]}
        install -m 0644 "$package_path" "$output/packages/$(basename "$package_path")"
    done

    printf '%s\n' "${packages[@]}" >"$output/PACKAGES"
    sha256sum "$catalog" | awk '{print $1}' >"$output/CATALOG_SHA256"
    sha256sum "$allowlist" | awk '{print $1}' >"$output/ALLOWLIST_SHA256"
    sha256sum "$policy_version" | awk '{print $1}' >"$output/POLICY_VERSION_SHA256"
    cp "$firmware_provenance" "$output/FIRMWARE_BUILD_PROVENANCE.txt"
    (
        cd "$output/packages"
        mapfile -d '' -t package_files < <(find . -maxdepth 1 -type f -name '*.apk' -printf '%P\0' | LC_ALL=C sort -z)
        sha256sum "${package_files[@]}" >../PACKAGE_SHA256SUMS
        sha256sum -c ../PACKAGE_SHA256SUMS
    )
    python3 "$(cd "$(dirname "$0")" && pwd)/addon-feed-plan.py" create \
        --candidate "$output" \
        --catalog "$catalog" \
        --allowlist "$allowlist" \
        --policy-version "$policy_version" \
        --firmware-provenance "$firmware_provenance" \
        --device jdcloud_er1_libwrt \
        --architecture aarch64_cortex-a53
    (
        cd "$output"
        mapfile -d '' -t candidate_files < <(find . -type f ! -name SHA256SUMS -printf '%P\0' | LC_ALL=C sort -z)
        sha256sum "${candidate_files[@]}" >SHA256SUMS
        sha256sum -c SHA256SUMS
    )
}

validate_candidate_input() {
    local candidate=$1
    local package_name
    local manifest_name
    local -a expected_files=()
    local -a actual_files=()
    local -a package_matches=()

    [[ -d $candidate/packages && ! -L $candidate/packages ]] \
        || fail 'candidate package directory is missing or unsafe'
    for manifest_name in PACKAGES PACKAGE_SHA256SUMS CATALOG_SHA256 ALLOWLIST_SHA256 \
        POLICY_VERSION_SHA256 FIRMWARE_BUILD_PROVENANCE.txt ADDON_PLAN.json VALIDATION.json SHA256SUMS; do
        [[ -s $candidate/$manifest_name && ! -L $candidate/$manifest_name ]] \
            || fail "candidate evidence is missing or unsafe: $manifest_name"
    done
    while IFS= read -r manifest_name; do
        case "$manifest_name" in
            PACKAGES|PACKAGE_SHA256SUMS|CATALOG_SHA256|ALLOWLIST_SHA256|POLICY_VERSION_SHA256|FIRMWARE_BUILD_PROVENANCE.txt|ADDON_PLAN.json|VALIDATION.json|SHA256SUMS|packages)
                ;;
            *)
                fail "candidate contains an unexpected top-level entry: $manifest_name"
                ;;
        esac
    done < <(find "$candidate" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
    (cd "$candidate" && sha256sum -c SHA256SUMS) \
        || fail 'candidate complete hash verification failed'
    if find "$candidate/packages" -mindepth 1 -maxdepth 1 ! -type f -print -quit | grep -q .; then
        fail 'candidate package directory contains a non-regular entry'
    fi
    if ! awk '
        NF != 2 { exit 1 }
        length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 1 }
        $2 !~ /^[A-Za-z0-9][A-Za-z0-9+_.-]*\.apk$/ { exit 1 }
        seen[$2]++ { exit 1 }
    ' "$candidate/PACKAGE_SHA256SUMS"; then
        fail 'candidate package hash manifest is malformed'
    fi
    mapfile -t expected_files < <(awk '{print $2}' "$candidate/PACKAGE_SHA256SUMS" | LC_ALL=C sort)
    mapfile -t actual_files < <(find "$candidate/packages" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
    cmp -s <(printf '%s\n' "${expected_files[@]}") <(printf '%s\n' "${actual_files[@]}") \
        || fail 'candidate package files differ from the package hash manifest'
    (cd "$candidate/packages" && sha256sum -c ../PACKAGE_SHA256SUMS) \
        || fail 'candidate package hash verification failed'

    while IFS= read -r package_name; do
        [[ $package_name =~ ^[A-Za-z0-9][A-Za-z0-9+_.-]*$ ]] \
            || fail "candidate package manifest contains an invalid package name: $package_name"
        mapfile -t package_matches < <(find "$candidate/packages" -maxdepth 1 -type f \
            -name "$package_name-*.apk" -printf '%f\n' | LC_ALL=C sort)
        (( ${#package_matches[@]} == 1 )) \
            || fail "candidate package manifest does not map exactly one APK for $package_name"
    done <"$candidate/PACKAGES"
    (( ${#expected_files[@]} > 0 )) || fail 'candidate contains no APK files'
    [[ $(grep -Ec '^[A-Za-z0-9][A-Za-z0-9+_.-]*$' "$candidate/PACKAGES") -eq ${#expected_files[@]} ]] \
        || fail 'candidate package manifest and APK file count differ'
}

sign() {
    local candidate=
    local output=
    local apk=
    local private_key=
    local public_key=
    local index_url=
    local key_dir
    local derived_public_key
    local expected_key_sha256
    local actual_key_sha256
    local -a package_files=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --candidate) candidate=$2; shift 2 ;;
            --output) output=$2; shift 2 ;;
            --apk) apk=$2; shift 2 ;;
            --private-key) private_key=$2; shift 2 ;;
            --public-key) public_key=$2; shift 2 ;;
            --index-url) index_url=$2; shift 2 ;;
            *) fail "unknown sign option: $1" ;;
        esac
    done

    [[ ${ALLOW_TAIYI_PLUGIN_FEED_SIGN:-} == 1 ]] \
        || fail 'sign requires ALLOW_TAIYI_PLUGIN_FEED_SIGN=1'
    require_absolute_dir "$candidate"
    require_absolute_file "$apk"
    require_absolute_file "$private_key"
    require_absolute_file "$public_key"
    key_dir=$(dirname "$private_key")
    require_absolute_dir "$key_dir"
    [[ $output == /* && ! -e $output ]] || fail "sign output must be an absent absolute path: $output"
    [[ $index_url =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*/[A-Za-z0-9._~/%+:-]*/packages\.adb$ ]] \
        && [[ $index_url != *..* ]] || fail 'index URL must be a stable HTTPS packages.adb path'
    [[ -s $candidate/PACKAGES && -s $candidate/PACKAGE_SHA256SUMS \
        && -s $candidate/FIRMWARE_BUILD_PROVENANCE.txt ]] \
        || fail 'candidate is missing required staged evidence'
    validate_candidate_input "$candidate"
    python3 "$(cd "$(dirname "$0")" && pwd)/addon-feed-plan.py" verify --candidate "$candidate"
    grep -qFx 'TaiyiPluginFeedMode: enabled' "$candidate/FIRMWARE_BUILD_PROVENANCE.txt" \
        || fail 'candidate does not originate from an enabled plugin-feed firmware build'
    grep -qFx 'WrtReleaseTreeState: clean' "$candidate/FIRMWARE_BUILD_PROVENANCE.txt" \
        || fail 'candidate does not originate from a clean-tree build'

    derived_public_key=$(mktemp)
    if ! openssl ec -in "$private_key" -pubout -out "$derived_public_key" >/dev/null 2>&1; then
        rm -f "$derived_public_key"
        fail 'unable to derive public key from plugin-feed private key'
    fi
    if ! cmp -s "$derived_public_key" "$public_key"; then
        rm -f "$derived_public_key"
        fail 'plugin-feed private key does not match the supplied public key'
    fi
    rm -f "$derived_public_key"
    expected_key_sha256=$(grep '^TaiyiPluginFeedPublicKeySha256: ' "$candidate/FIRMWARE_BUILD_PROVENANCE.txt" | sed 's/^[^:]*: //')
    actual_key_sha256=$(sha256sum "$public_key" | awk '{print $1}')
    [[ $expected_key_sha256 == "$actual_key_sha256" ]] \
        || fail 'plugin-feed public key does not match firmware provenance'

    mkdir -p "$output"
    cp "$candidate/PACKAGES" "$candidate/PACKAGE_SHA256SUMS" \
        "$candidate/CATALOG_SHA256" "$candidate/ALLOWLIST_SHA256" \
        "$candidate/POLICY_VERSION_SHA256" "$candidate/ADDON_PLAN.json" \
        "$candidate/VALIDATION.json" \
        "$candidate/FIRMWARE_BUILD_PROVENANCE.txt" "$output/"
    while IFS= read -r package_file; do
        install -m 0644 "$candidate/packages/$package_file" "$output/$package_file"
    done < <(awk '{print $2}' "$candidate/PACKAGE_SHA256SUMS")
    (
        cd "$output"
        sha256sum -c PACKAGE_SHA256SUMS
        mapfile -d '' -t package_files < <(find . -maxdepth 1 -type f -name '*.apk' -printf '%P\0' | LC_ALL=C sort -z)
        (( ${#package_files[@]} > 0 )) || exit 1
        "$apk" mkndx --root "$candidate" --keys-dir "$key_dir" --allow-untrusted \
            --sign "$private_key" --output packages.adb "${package_files[@]}"
        test -s packages.adb
        {
            printf 'IndexUrl: %s\n' "$index_url"
            printf 'PublicKeySha256: %s\n' "$actual_key_sha256"
            cat FIRMWARE_BUILD_PROVENANCE.txt
        } >PLUGIN_FEED_PROVENANCE.txt
        mapfile -d '' -t release_files < <(find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' | LC_ALL=C sort -z)
        sha256sum "${release_files[@]}" >SHA256SUMS
        sha256sum -c SHA256SUMS
    )
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
command=$1
shift
case "$command" in
    stage) stage "$@" ;;
    sign) sign "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
