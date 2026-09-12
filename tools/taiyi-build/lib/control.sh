#!/usr/bin/env bash
# Sourceable control-state helpers. This file intentionally does not change the
# caller's shell options.

taiyi_control_error() {
    printf 'Error: %s\n' "$*" >&2
    return 1
}

taiyi_control_require_write() {
    [[ ${ALLOW_CONTROL_WRITE:-0} == 1 ]] \
        || taiyi_control_error 'control writes require explicit ALLOW_CONTROL_WRITE=1'
}

taiyi_control_validate_run_token() {
    local token=${1:-}
    [[ $token =~ ^[A-Za-z0-9][A-Za-z0-9._-]{15,127}$ ]] \
        || taiyi_control_error 'invalid run token format'
}

taiyi_control_generate_run_token() {
    local token
    command -v od >/dev/null 2>&1 \
        || taiyi_control_error 'od is required to generate a run token' \
        || return 1
    token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    taiyi_control_validate_run_token "$token" || return 1
    printf '%s\n' "$token"
}

taiyi_control_validate_dir() {
    local control_dir=${TAIYI_CONTROL_DIR:-}
    [[ $control_dir == /* ]] \
        || taiyi_control_error 'TAIYI_CONTROL_DIR must be an explicit absolute path' \
        || return 1
    [[ -d $control_dir && ! -L $control_dir ]] \
        || taiyi_control_error 'TAIYI_CONTROL_DIR must be an existing, non-symlink directory'
}

taiyi_control_atomic_write() {
    local state_name=${1:-}
    local control_dir tmp target

    taiyi_control_require_write || return 1
    taiyi_control_validate_dir || return 1
    [[ $state_name =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
        || taiyi_control_error 'state name must be a single safe path component' \
        || return 1

    control_dir=${TAIYI_CONTROL_DIR%/}
    target=$control_dir/$state_name
    [[ ! -L $target ]] \
        || taiyi_control_error 'refusing to replace a symlink state target' \
        || return 1
    tmp=$control_dir/.${state_name}.tmp.$$.${RANDOM}
    (set -o noclobber; umask 077; printf '%s' "$(cat)" >"$tmp") || {
        taiyi_control_error 'unable to create temporary control state'
        return 1
    }
    if ! mv -- "$tmp" "$target"; then
        rm -f -- "$tmp"
        taiyi_control_error 'unable to publish control state'
        return 1
    fi
}
