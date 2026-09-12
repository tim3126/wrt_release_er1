#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf 'Usage: %s --spec /absolute/path/to/run-spec.env\n' "${0##*/}"
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

normalize_path() {
    realpath -m -- "$1"
}

path_is_within() {
    local child=$1
    local parent=$2
    [[ $child == "$parent" || $child == "$parent"/* ]]
}

reject_unsafe_cache_path() {
    local name=$1
    local value=$2
    local normalized lower component

    normalized=$(normalize_path "$value")
    lower=${normalized,,}
    IFS='/' read -r -a components <<<"$lower"
    for component in "${components[@]}"; do
        case "$component" in
            artifact|artifacts|candidate|candidates|firmware|bin|build_dir|staging_dir|rootfs|keys|key-build*|signing|signed|indexes|private|private-key*|recovery|secret|secrets|token|tokens)
                fail "$name contains a sensitive or artifact path component"
                ;;
        esac
    done
}

parse_spec() {
    local file=$1
    local line key value line_number=0

    [[ -f $file && ! -L $file ]] || fail "spec must be a regular, non-symlink file"
    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number += 1))
        [[ $line != *$'\r'* ]] || fail "spec contains CR bytes at line $line_number"
        [[ -z $line || $line == \#* ]] && continue
        [[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] \
            || fail "invalid spec syntax at line $line_number"
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case "$key" in
            RUN_WORKSPACE_DIR|RUN_SOURCE_DIR|RUN_CONTROL_DIR|RUN_DL_CACHE_DIR|RUN_CCACHE_DIR|RUN_ARTIFACT_DIR|CACHE_SCOPES|CACHE_MANIFEST_FILE|CACHE_IDENTITY_FILE|TOOLCHAIN_IDENTITY)
                ;;
            *) fail "unsupported spec field: $key" ;;
        esac
        [[ -z ${seen[$key]+x} ]] || fail "duplicate spec field: $key"
        seen[$key]=1
        values[$key]=$value
    done <"$file"
}

spec_file=
while (($#)); do
    case "$1" in
        --spec)
            (($# >= 2)) || fail "--spec requires a file"
            [[ -z $spec_file ]] || fail "--spec may be provided only once"
            spec_file=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) fail "unknown argument: $1" ;;
    esac
done
[[ -n $spec_file ]] || fail "an explicit --spec file is required"
require_absolute "--spec" "$spec_file"
command -v realpath >/dev/null 2>&1 || fail "realpath is required"

declare -A values=()
declare -A seen=()
parse_spec "$spec_file"

required_fields=(
    RUN_WORKSPACE_DIR
    RUN_SOURCE_DIR
    RUN_CONTROL_DIR
    RUN_DL_CACHE_DIR
    RUN_CCACHE_DIR
    RUN_ARTIFACT_DIR
    CACHE_SCOPES
    CACHE_MANIFEST_FILE
    CACHE_IDENTITY_FILE
    TOOLCHAIN_IDENTITY
)
for field in "${required_fields[@]}"; do
    [[ -n ${values[$field]:-} ]] || fail "missing or empty required field: $field"
done

path_fields=(
    RUN_WORKSPACE_DIR
    RUN_SOURCE_DIR
    RUN_CONTROL_DIR
    RUN_DL_CACHE_DIR
    RUN_CCACHE_DIR
    RUN_ARTIFACT_DIR
    CACHE_MANIFEST_FILE
    CACHE_IDENTITY_FILE
)
for field in "${path_fields[@]}"; do
    require_absolute "$field" "${values[$field]}"
    values[$field]=$(normalize_path "${values[$field]}")
done

workspace=${values[RUN_WORKSPACE_DIR]}
control=${values[RUN_CONTROL_DIR]}
artifact=${values[RUN_ARTIFACT_DIR]}
dl_cache=${values[RUN_DL_CACHE_DIR]}
ccache=${values[RUN_CCACHE_DIR]}

path_is_within "$control" "$workspace" \
    && fail "RUN_CONTROL_DIR must not be inside RUN_WORKSPACE_DIR"
[[ ${dl_cache##*/} == dl ]] || fail "RUN_DL_CACHE_DIR must end in /dl"
[[ ${ccache##*/} == .ccache ]] || fail "RUN_CCACHE_DIR must end in /.ccache"
reject_unsafe_cache_path "RUN_DL_CACHE_DIR" "$dl_cache"
reject_unsafe_cache_path "RUN_CCACHE_DIR" "$ccache"
path_is_within "$dl_cache" "$artifact" \
    && fail "RUN_DL_CACHE_DIR must not be inside RUN_ARTIFACT_DIR"
path_is_within "$ccache" "$artifact" \
    && fail "RUN_CCACHE_DIR must not be inside RUN_ARTIFACT_DIR"
path_is_within "$artifact" "$dl_cache" \
    && fail "RUN_ARTIFACT_DIR must not be inside RUN_DL_CACHE_DIR"
path_is_within "$artifact" "$ccache" \
    && fail "RUN_ARTIFACT_DIR must not be inside RUN_CCACHE_DIR"

IFS=',' read -r -a scopes <<<"${values[CACHE_SCOPES]}"
declare -A scope_seen=()
for scope in "${scopes[@]}"; do
    case "$scope" in
        dl|.ccache) ;;
        *) fail "CACHE_SCOPES may contain only dl and .ccache" ;;
    esac
    [[ -z ${scope_seen[$scope]+x} ]] || fail "CACHE_SCOPES contains a duplicate scope"
    scope_seen[$scope]=1
done
[[ ${#scope_seen[@]} -eq 2 ]] \
    || fail "CACHE_SCOPES must explicitly contain both dl and .ccache"

case "${values[TOOLCHAIN_IDENTITY],,}" in
    unknown|unset|none|not-applicable) fail "TOOLCHAIN_IDENTITY must be explicit" ;;
esac

printf '%s\n' \
    'run spec validation passed' \
    '  workspace: absolute path validated (redacted)' \
    '  source: absolute path validated (redacted)' \
    '  control: absolute and outside workspace (redacted)' \
    '  caches: dl and .ccache only (paths redacted)' \
    '  artifact: absolute and cache-separated (redacted)' \
    '  cache metadata: explicit paths validated (redacted)' \
    '  toolchain identity: present (value redacted)' \
    'No build, Docker, copy, delete, or filesystem write was performed.'
