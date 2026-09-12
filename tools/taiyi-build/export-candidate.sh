#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: ${0##*/} plan --source /absolute/source --evidence /absolute/evidence --destination /absolute/new-candidate --policy /absolute/policy
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

(($#)) || {
    usage
    exit 1
}
command_name=$1
shift
[[ $command_name == plan ]] || fail "only the plan subcommand is implemented"

declare -A args=()
while (($#)); do
    case "$1" in
        --source|--evidence|--destination|--policy)
            (($# >= 2)) || fail "$1 requires a path"
            key=${1#--}
            [[ -z ${args[$key]+x} ]] || fail "$1 may be provided only once"
            args[$key]=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) fail "unknown argument: $1" ;;
    esac
done

for key in source evidence destination policy; do
    [[ -n ${args[$key]:-} ]] || fail "an explicit --$key path is required"
    require_absolute "--$key" "${args[$key]}"
done
[[ -d ${args[source]} && ! -L ${args[source]} ]] \
    || fail "--source must be an existing, non-symlink directory"
[[ -d ${args[evidence]} && ! -L ${args[evidence]} ]] \
    || fail "--evidence must be an existing, non-symlink directory"
[[ -f ${args[policy]} && ! -L ${args[policy]} ]] \
    || fail "--policy must be an existing, non-symlink regular file"
[[ ! -e ${args[destination]} && ! -L ${args[destination]} ]] \
    || fail "--destination must not already exist"

printf '%s\n' \
    'candidate export plan validated (all paths redacted)' \
    '  1. Parse the explicit policy and fail closed on unknown entries.' \
    '  2. Match source and evidence files against the policy whitelist.' \
    '  3. Reject case-folded path conflicts before export.' \
    '  4. Verify source and evidence hashes against external manifests.' \
    '  5. Require the destination to remain absent until an authorized exporter runs.' \
    '  6. After an authorized copy, recompute destination hashes and compare them.' \
    'Plan only: no directory was created and no file was copied, removed, or modified.'
