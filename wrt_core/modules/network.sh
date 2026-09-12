#!/usr/bin/env bash

network_retry() {
    local max_attempts="${NETWORK_RETRY_MAX:-5}"
    local delay_seconds="${NETWORK_RETRY_DELAY:-5}"
    local attempt=1
    local exit_code

    while true; do
        "$@" && return 0
        exit_code=$?
        if ((attempt >= max_attempts)); then
            return "$exit_code"
        fi

        echo "网络命令失败，${delay_seconds}s 后重试 ($attempt/$max_attempts): $*" >&2
        sleep "$delay_seconds"
        attempt=$((attempt + 1))
        delay_seconds=$((delay_seconds * 2))
    done
}

git_retry() {
    local max_attempts="${NETWORK_RETRY_MAX:-5}"
    local delay_seconds="${NETWORK_RETRY_DELAY:-5}"
    local attempt=1
    local exit_code
    local clone_target=""

    if [[ ${1:-} == "clone" ]]; then
        clone_target="${@: -1}"
    fi

    while true; do
        git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 "$@" && return 0
        exit_code=$?
        if ((attempt >= max_attempts)); then
            return "$exit_code"
        fi

        if [[ -n "$clone_target" && -e "$clone_target" ]]; then
            rm -rf "$clone_target"
        fi

        echo "Git 网络操作失败，${delay_seconds}s 后重试 ($attempt/$max_attempts): git $*" >&2
        sleep "$delay_seconds"
        attempt=$((attempt + 1))
        delay_seconds=$((delay_seconds * 2))
    done
}

curl_retry() {
    network_retry curl --retry 3 --retry-delay 2 --retry-all-errors "$@"
}

wget_retry() {
    network_retry wget --tries=3 --waitretry=2 "$@"
}

checkout_locked_commit() {
    local repo_dir="$1"
    local expected_commit="$2"
    local actual_commit

    if ! git -C "$repo_dir" cat-file -e "$expected_commit^{commit}" 2>/dev/null; then
        git_retry -C "$repo_dir" fetch --depth 1 origin "$expected_commit"
    fi
    git_retry -C "$repo_dir" checkout --detach --quiet "$expected_commit"
    actual_commit=$(git -C "$repo_dir" rev-parse HEAD)
    if [[ "$actual_commit" != "$expected_commit" ]]; then
        echo "错误：$repo_dir 源码提交不匹配：$actual_commit != $expected_commit" >&2
        return 1
    fi
}
