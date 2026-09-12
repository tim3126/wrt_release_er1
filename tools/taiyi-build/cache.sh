#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: ${0##*/} verify --manifest /absolute/cache-manifest.env --identity /absolute/cache-identity.env
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_absolute() {
    local name=$1
    local value=$2
    [[ $value == /* ]] || fail "$name must be an absolute POSIX path"
}

parse_kv_file() {
    local file=$1
    local destination=$2
    local kind=$3
    local -n output=$destination
    local line key value line_number=0

    [[ -f $file && ! -L $file ]] || fail "$kind must be a regular, non-symlink file"
    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number += 1))
        [[ $line != *$'\r'* ]] || fail "$kind contains CR bytes at line $line_number"
        [[ -z $line || $line == \#* ]] && continue
        [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] \
            || fail "invalid $kind syntax at line $line_number"
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case "$kind:$key" in
            manifest:CACHE_SCOPE|manifest:CACHE_PATH|manifest:IDENTITY_SHA256|identity:CACHE_SCOPE|identity:CACHE_IDENTITY|identity:TOOLCHAIN_IDENTITY|identity:BUILD_IDENTITY)
                ;;
            *) fail "unsupported $kind field: $key" ;;
        esac
        [[ -z ${output[$key]+x} ]] || fail "duplicate $kind field: $key"
        output[$key]=$value
    done <"$file"
}

validate_identity_value() {
    local name=$1
    local value=$2
    [[ -n $value ]] || fail "$name must not be empty"
    case "${value,,}" in
        unknown|unset|none|not-applicable) fail "$name must be explicit" ;;
    esac
    [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9._:@/+,-]{2,255}$ ]] \
        || fail "$name contains unsupported characters or has an invalid length"
}

(($#)) || {
    usage
    exit 1
}
command_name=$1
shift
[[ $command_name == verify ]] || fail "only the verify subcommand is implemented"

manifest_file=
identity_file=
while (($#)); do
    case "$1" in
        --manifest)
            (($# >= 2)) || fail "--manifest requires a file"
            [[ -z $manifest_file ]] || fail "--manifest may be provided only once"
            manifest_file=$2
            shift 2
            ;;
        --identity)
            (($# >= 2)) || fail "--identity requires a file"
            [[ -z $identity_file ]] || fail "--identity may be provided only once"
            identity_file=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) fail "unknown argument: $1" ;;
    esac
done
[[ -n $manifest_file ]] || fail "an explicit --manifest file is required"
[[ -n $identity_file ]] || fail "an explicit --identity file is required"
require_absolute "--manifest" "$manifest_file"
require_absolute "--identity" "$identity_file"

declare -A manifest=()
declare -A identity=()
parse_kv_file "$manifest_file" manifest manifest
parse_kv_file "$identity_file" identity identity

for field in CACHE_SCOPE CACHE_PATH IDENTITY_SHA256; do
    [[ -n ${manifest[$field]:-} ]] || fail "manifest is missing $field"
done
for field in CACHE_SCOPE CACHE_IDENTITY; do
    [[ -n ${identity[$field]:-} ]] || fail "identity is missing $field"
done

scope=${manifest[CACHE_SCOPE]}
case "$scope" in
    dl|.ccache) ;;
    *) fail "manifest CACHE_SCOPE must be dl or .ccache" ;;
esac
[[ ${identity[CACHE_SCOPE]} == "$scope" ]] \
    || fail "manifest and identity CACHE_SCOPE values differ"
require_absolute "manifest CACHE_PATH" "${manifest[CACHE_PATH]}"
[[ -d ${manifest[CACHE_PATH]} && ! -L ${manifest[CACHE_PATH]} ]] \
    || fail "manifest CACHE_PATH must be an existing, non-symlink directory"
[[ ${manifest[CACHE_PATH]%/} == */"$scope" ]] \
    || fail "manifest CACHE_PATH must end in /$scope"
[[ ${manifest[IDENTITY_SHA256]} =~ ^[0-9a-f]{64}$ ]] \
    || fail "manifest IDENTITY_SHA256 must be a lowercase SHA-256"

validate_identity_value "CACHE_IDENTITY" "${identity[CACHE_IDENTITY]}"
if [[ $scope == .ccache ]]; then
    [[ -n ${identity[TOOLCHAIN_IDENTITY]:-} ]] \
        || fail ".ccache identity must contain TOOLCHAIN_IDENTITY"
    validate_identity_value "TOOLCHAIN_IDENTITY" "${identity[TOOLCHAIN_IDENTITY]}"
fi
if [[ -n ${identity[BUILD_IDENTITY]:-} ]]; then
    validate_identity_value "BUILD_IDENTITY" "${identity[BUILD_IDENTITY]}"
fi

actual_identity_sha256=$(sha256sum "$identity_file" | awk '{print $1}')
[[ $actual_identity_sha256 == "${manifest[IDENTITY_SHA256]}" ]] \
    || fail "identity file SHA-256 does not match the manifest"

printf 'cache verification passed: scope=%s; path=<redacted>; identity=<redacted>; identity SHA-256 verified\n' "$scope"
printf '%s\n' 'No cache content was copied, removed, modified, or enumerated.'
