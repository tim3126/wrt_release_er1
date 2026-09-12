#!/usr/bin/env bash

set -e

# 定位 wrt_core，兼容仓库根目录或上级目录调用。
if [ -d "wrt_core" ]; then
    WRT_CORE_PATH="wrt_core"
elif [ -d "../wrt_core" ]; then
    WRT_CORE_PATH="../wrt_core"
else
    echo "Error: wrt_core directory not found!"
    exit 1
fi

BASE_PATH=$(cd "$WRT_CORE_PATH" && pwd)

source "$BASE_PATH/modules/profile_verify.sh"
source "$BASE_PATH/modules/build_state.sh"

REPO_ROOT=$(cd "$BASE_PATH/.." && pwd)

Dev=$1
Build_Mod=$2

SUPPORTED_DEVS=()

# 只有 compilecfg 与 deconfig 同名成对存在的设备才可构建。
collect_supported_devs() {
    local ini_file
    local dev_key
    local IFS

    SUPPORTED_DEVS=()

    for ini_file in "$BASE_PATH"/compilecfg/*.ini; do
        [[ -f "$ini_file" ]] || continue

        dev_key=$(basename "$ini_file" .ini)
        if [[ -f "$BASE_PATH/deconfig/$dev_key.config" ]]; then
            SUPPORTED_DEVS+=("$dev_key")
        fi
    done

    if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
        return
    fi

    IFS=$'\n' SUPPORTED_DEVS=($(printf '%s\n' "${SUPPORTED_DEVS[@]}" | LC_ALL=C sort))
}

print_usage() {
    echo "Usage: $0 <device> [debug|resume|container_prepare|container|container_debug|container_resume|config_preview]"
    echo "       ./start.sh"
}

print_supported_devs() {
    local index

    echo "Supported devices:"
    for ((index = 0; index < ${#SUPPORTED_DEVS[@]}; index++)); do
        printf "  %d) %s\n" "$((index + 1))" "${SUPPORTED_DEVS[index]}"
    done
}

prompt_select_dev() {
    local input
    local selected_index

    while true; do
        print_supported_devs
        printf "Select device by number (q to quit): "

        if ! read -r input; then
            echo
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
            selected_index=${BASH_REMATCH[1]}
            if ((selected_index >= 1 && selected_index <= ${#SUPPORTED_DEVS[@]})); then
                Dev=${SUPPORTED_DEVS[selected_index - 1]}
                return
            fi
        fi

        echo "Invalid selection. Please enter a number between 1 and ${#SUPPORTED_DEVS[@]}."
    done
}

prompt_select_build_mode() {
    local input

    while true; do
        echo "Build mode:"
        echo "  1) normal"
        echo "  2) debug"
        echo "  3) container_prepare"
        echo "  4) container"
        echo "  5) container_debug"
        echo "  6) container_resume"
        echo "  7) config_preview"
        printf "Select build mode (1-7, q to quit): "

        if ! read -r input; then
            echo
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*1[[:space:]]*$ ]]; then
            Build_Mod=""
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*2[[:space:]]*$ ]]; then
            Build_Mod="debug"
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*3[[:space:]]*$ ]]; then
            Build_Mod="container_prepare"
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*4[[:space:]]*$ ]]; then
            Build_Mod="container"
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*5[[:space:]]*$ ]]; then
            Build_Mod="container_debug"
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*6[[:space:]]*$ ]]; then
            Build_Mod="container_resume"
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*7[[:space:]]*$ ]]; then
            Build_Mod="config_preview"
            return
        fi

        echo "Invalid selection. Please enter 1, 2, 3, 4, 5, 6, or 7."
    done
}

is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}

validate_build_mode() {
    case "$Build_Mod" in
        ""|debug|resume|container_prepare|container|container_debug|container_resume|config_preview)
            return 0
            ;;
        *)
            echo "Error: unsupported build mode: $Build_Mod" >&2
            print_usage >&2
            exit 1
            ;;
    esac
}

if [[ $# -eq 0 ]]; then
    collect_supported_devs

    if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
        echo "Error: no supported devices found."
        exit 1
    fi

    if ! is_interactive_terminal; then
        print_usage
        print_supported_devs
        exit 1
    fi

    prompt_select_dev

    if [[ -z $Build_Mod ]]; then
        prompt_select_build_mode
    fi
fi

CONFIG_FILE="$BASE_PATH/deconfig/$Dev.config"
INI_FILE="$BASE_PATH/compilecfg/$Dev.ini"

if [[ ! -f $CONFIG_FILE ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f $INI_FILE ]]; then
    echo "INI file not found: $INI_FILE"
    exit 1
fi

validate_build_mode

read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE"
}

resolve_positive_job_count() {
    local variable_name=$1
    local default_value=$2
    local value=${!variable_name:-$default_value}

    if [[ ! $value =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: $variable_name must be a positive integer, got '$value'." >&2
        exit 1
    fi

    printf -v "$variable_name" '%d' "$value"
    export "$variable_name"
}

resolve_parallel_jobs() {
    local cpu_count
    local default_download_jobs
    local default_build_jobs

    cpu_count=$(nproc)
    default_download_jobs=$((cpu_count * 2))
    ((default_download_jobs > 16)) && default_download_jobs=16
    default_build_jobs=$cpu_count
    ((default_build_jobs > 8)) && default_build_jobs=8

    resolve_positive_job_count DOWNLOAD_JOBS "$default_download_jobs"
    resolve_positive_job_count BUILD_JOBS "$default_build_jobs"
}

resolve_parallel_jobs

CONFIG_FRAGMENT_DIR="$BASE_PATH/deconfig/fragments"
DEFAULT_CONFIG_FRAGMENTS=()
ADD_CONFIG_FRAGMENT_LIST=()
REMOVE_CONFIG_FRAGMENT_LIST=()
EFFECTIVE_CONFIG_FRAGMENTS=()

parse_fragment_csv() {
    local csv=$1
    local output_array=$2
    local item
    local -n target_array="$output_array"

    target_array=()
    csv=${csv//[[:space:]]/}
    [[ -n $csv ]] || return 0

    IFS=',' read -r -a target_array <<< "$csv"
    for item in "${target_array[@]}"; do
        if [[ -z $item ]]; then
            echo "Error: empty config fragment name in '$csv'." >&2
            exit 1
        fi

        if [[ ! $item =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
            echo "Error: invalid config fragment name '$item'." >&2
            exit 1
        fi
    done
}

fragment_in_list() {
    local fragment=$1
    shift
    local item

    for item in "$@"; do
        [[ $item == "$fragment" ]] && return 0
    done

    return 1
}

append_unique_fragment() {
    local fragment=$1
    local output_array=$2
    local -n target_array="$output_array"

    fragment_in_list "$fragment" "${target_array[@]}" && return 0
    target_array+=("$fragment")
}

validate_enable_fragment() {
    local fragment=$1
    local fragment_path="$CONFIG_FRAGMENT_DIR/$fragment.config"

    if [[ ! -f $fragment_path ]]; then
        echo "Error: config fragment not found: $fragment_path" >&2
        exit 1
    fi
}

join_fragments() {
    local IFS=','
    echo "$*"
}

resolve_config_fragments() {
    local fragment
    local candidate_fragments=()

    parse_fragment_csv "$(read_ini_by_key "CONFIG_FRAGMENTS")" DEFAULT_CONFIG_FRAGMENTS
    parse_fragment_csv "${ADD_CONFIG_FRAGMENTS:-}" ADD_CONFIG_FRAGMENT_LIST
    parse_fragment_csv "${REMOVE_CONFIG_FRAGMENTS:-}" REMOVE_CONFIG_FRAGMENT_LIST

    for fragment in "${DEFAULT_CONFIG_FRAGMENTS[@]}" "${ADD_CONFIG_FRAGMENT_LIST[@]}" "${REMOVE_CONFIG_FRAGMENT_LIST[@]}"; do
        validate_enable_fragment "$fragment"
    done

    for fragment in "${DEFAULT_CONFIG_FRAGMENTS[@]}" "${ADD_CONFIG_FRAGMENT_LIST[@]}"; do
        append_unique_fragment "$fragment" candidate_fragments
    done

    EFFECTIVE_CONFIG_FRAGMENTS=()
    for fragment in "${candidate_fragments[@]}"; do
        if ! fragment_in_list "$fragment" "${REMOVE_CONFIG_FRAGMENT_LIST[@]}"; then
            EFFECTIVE_CONFIG_FRAGMENTS+=("$fragment")
        fi
    done

    for fragment in "${REMOVE_CONFIG_FRAGMENT_LIST[@]}"; do
        if [[ $fragment == "nss" ]]; then
            echo "Warning: removing platform fragment 'nss' is high risk." >&2
        fi
    done
}

print_config_fragment_summary() {
    echo "Config fragments:"
    echo "  Device: $Dev"
    echo "  Default fragments: $(join_fragments "${DEFAULT_CONFIG_FRAGMENTS[@]}")"
    echo "  Add fragments: $(join_fragments "${ADD_CONFIG_FRAGMENT_LIST[@]}")"
    echo "  Remove fragments: $(join_fragments "${REMOVE_CONFIG_FRAGMENT_LIST[@]}")"
    echo "  Effective fragments: $(join_fragments "${EFFECTIVE_CONFIG_FRAGMENTS[@]}")"
}

print_config_preview() {
    print_config_fragment_summary
    echo "Config assembly order:"
    echo "  1) $CONFIG_FILE"
    echo "  2) $BASE_PATH/deconfig/compile_base.config"

    local order=3
    local fragment
    for fragment in "${EFFECTIVE_CONFIG_FRAGMENTS[@]}"; do
        echo "  $order) $CONFIG_FRAGMENT_DIR/$fragment.config"
        order=$((order + 1))
    done

}

prepare_container_image() {
    local base_image=$1
    local image_name=$2
    local container_tmp_Dockerfile
    local container_context

    container_tmp_Dockerfile=$(mktemp Dockerfile.XXXXXX)
    container_context=$(mktemp -d)

    cleanup_container_dockerfile() {
        rm -f "$container_tmp_Dockerfile"
        rm -rf "$container_context"
    }

    trap cleanup_container_dockerfile RETURN

    docker pull "$base_image"
    cat > "$container_tmp_Dockerfile" <<EOF
FROM $base_image
USER root
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    sudo ca-certificates git jq build-essential cmake g++ clang bison flex libelf-dev \
    libncurses-dev zlib1g-dev python3 python3-pyelftools python3-setuptools \
    pkg-config libssl-dev rsync unzip bzip2 xz-utils patch diffutils \
    subversion swig time xsltproc zstd device-tree-compiler ccache \
    ninja-build gettext gawk gcc-multilib g++-multilib file wget curl \
    dos2unix libfuse-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
RUN test "$(id -u ubuntu)" = "1000" \
    && test "$(id -g ubuntu)" = "1000" \
    && test -d /home/ubuntu
ENV HOME=/home/ubuntu
USER ubuntu
RUN git config --global pull.rebase false
RUN git config --global advice.detachedHead false
CMD ["bash", "wrt_core/build_container.sh", "$image_name"]
EOF
    docker build -t "$image_name" -f "$container_tmp_Dockerfile" "$container_context"
}

run_container_build() {
    local container_build_mod=$1
    local container_image_mode=${2:-prepare}
    local build_target_sdk
    local container_name
    local -a docker_tty_args=()

    build_target_sdk=$(read_ini_by_key "BUILD_TARGET_SDK")

    if [[ -z "$build_target_sdk" ]]; then
        echo "BUILD_TARGET_SDK not specified in $INI_FILE. Using default: openwrt-25.12"
        build_target_sdk="immortalwrt/sdk:openwrt-25.12"
    fi

    container_name="$(echo "$Dev" | tr '[:upper:]' '[:lower:]' | tr '/:' '-_')-build-container"

    if [[ $container_image_mode == "prepare" ]]; then
        prepare_container_image "$build_target_sdk" "$container_name"
    elif [[ $container_image_mode != "reuse" ]]; then
        echo "Error: unsupported container image mode: $container_image_mode" >&2
        exit 1
    fi

    if ! BUILD_CONTAINER_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$container_name" 2>/dev/null); then
        echo "Error: container image $container_name is unavailable; run container_prepare first." >&2
        exit 1
    fi
    export BUILD_CONTAINER_IMAGE_ID
    if [[ -z "$BUILD_CONTAINER_IMAGE_ID" ]]; then
        echo "Error: failed to resolve container image ID for $container_name." >&2
        exit 1
    fi
    if is_interactive_terminal; then
        docker_tty_args=(-it)
    fi

    docker run --rm "${docker_tty_args[@]}" \
        -v "$REPO_ROOT":/build \
        -w /build \
        -e ADD_CONFIG_FRAGMENTS \
        -e REMOVE_CONFIG_FRAGMENTS \
        -e DOWNLOAD_JOBS \
        -e BUILD_JOBS \
        -e WRT_RELEASE_COMMIT \
        -e WRT_RELEASE_TREE_STATE \
        -e WRT_RELEASE_INPUT_SHA256 \
        -e BUILD_CONTAINER_IMAGE_ID \
        --shm-size=8g \
        --ipc=shareable \
        --ulimit nofile=65535:65535 \
        "$container_name" \
        bash wrt_core/build_container.sh "$Dev" "$container_build_mod"
}

remove_uhttpd_dependency() {
    local config_path="$BASE_PATH/../$BUILD_DIR/.config"
    local luci_makefile_path="$BASE_PATH/../$BUILD_DIR/feeds/luci/collections/luci/Makefile"

    if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$config_path"; then
        if [ -f "$luci_makefile_path" ]; then
            sed -i '/luci-light/d' "$luci_makefile_path"
            echo "Removed uhttpd (luci-light) dependency as luci-app-quickfile (nginx) is enabled."
        fi
    fi
}

if [[ $Build_Mod == "container_prepare" ]]; then
    build_target_sdk=$(read_ini_by_key "BUILD_TARGET_SDK")
    if [[ -z "$build_target_sdk" ]]; then
        echo "Error: BUILD_TARGET_SDK must be pinned for container_prepare." >&2
        exit 1
    fi
    container_name="$(echo "$Dev" | tr '[:upper:]' '[:lower:]' | tr '/:' '-_')-build-container"
    prepare_container_image "$build_target_sdk" "$container_name"
    exit 0
fi

if [[ $Build_Mod == "container" ]]; then
    run_container_build ""
    exit 0
fi

if [[ $Build_Mod == "container_debug" ]]; then
    run_container_build "debug"
    exit 0
fi

if [[ $Build_Mod == "container_resume" ]]; then
    run_container_build "resume" "reuse"
    exit 0
fi

apply_config() {
    local fragment

    \cp -f "$CONFIG_FILE" "$BASE_PATH/../$BUILD_DIR/.config"

    cat "$BASE_PATH/deconfig/compile_base.config" >> "$BASE_PATH/../$BUILD_DIR/.config"

    for fragment in "${EFFECTIVE_CONFIG_FRAGMENTS[@]}"; do
        cat "$CONFIG_FRAGMENT_DIR/$fragment.config" >> "$BASE_PATH/../$BUILD_DIR/.config"
    done

}

# 读取设备元信息，确定上游源码和构建目录。
REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
BUILD_DIR=$(read_ini_by_key "BUILD_DIR")
COMMIT_HASH=$(read_ini_by_key "COMMIT_HASH")
COMMIT_HASH=${COMMIT_HASH:-none}
THEME_SET=$(read_ini_by_key "THEME_SET")
THEME_SET=${THEME_SET:-argon}
CUSTOM_FEED_EXCLUDES=$(read_ini_by_key "CUSTOM_FEED_EXCLUDES")

resolve_config_fragments

if [[ $Build_Mod == "config_preview" ]]; then
    print_config_preview
    exit 0
fi

if [[ -d action_build ]]; then
    # GitHub Actions 使用 action_build 作为固定构建目录。
    BUILD_DIR="action_build"
fi

source_dir="$BASE_PATH/../$BUILD_DIR"
resolve_release_identity
if [[ $Build_Mod == "resume" ]]; then
    if [[ ! -d "$source_dir/.git" || ! -f "$source_dir/.config" ]]; then
        echo "Error: resume requires an existing prepared source tree and .config: $source_dir" >&2
        exit 1
    fi

    actual_commit=$(git -C "$source_dir" rev-parse HEAD)
    if [[ $actual_commit != "$COMMIT_HASH" ]]; then
        echo "Error: resume source commit mismatch: expected $COMMIT_HASH, got $actual_commit." >&2
        exit 1
    fi

    validate_build_state "$source_dir"
    print_config_fragment_summary
    cd "$source_dir"
    verify_selected_profile "$Dev" "$source_dir/.config" "$source_dir" "$COMMIT_HASH"
else
    "$BASE_PATH/update.sh" "$REPO_URL" "$REPO_BRANCH" "$BUILD_DIR" "$COMMIT_HASH" "$THEME_SET" "$CUSTOM_FEED_EXCLUDES" "$Dev"

    apply_config
    print_config_fragment_summary
    remove_uhttpd_dependency

    cd "$source_dir"
    make defconfig
    verify_selected_profile "$Dev" "$source_dir/.config" "$source_dir" "$COMMIT_HASH"
    prepare_apk_build_keys "$source_dir"
    write_build_state "$source_dir"
fi

if grep -qE "^CONFIG_TARGET_x86_64=y" "$CONFIG_FILE"; then
    DISTFEEDS_PATH="$BASE_PATH/../$BUILD_DIR/package/emortal/default-settings/files/99-distfeeds.conf"
    if [ -d "${DISTFEEDS_PATH%/*}" ] && [ -f "$DISTFEEDS_PATH" ]; then
        sed -i 's/aarch64_cortex-a53/x86_64/g' "$DISTFEEDS_PATH"
    fi
fi

if [[ $Build_Mod == "debug" ]]; then
    exit 0
fi

TARGET_DIR="$BASE_PATH/../$BUILD_DIR/bin/targets"
if [[ -d $TARGET_DIR ]]; then
    find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec rm -f {} +
fi

echo "Build parallelism: download=$DOWNLOAD_JOBS compile=$BUILD_JOBS"
make download -j"$DOWNLOAD_JOBS"
make -j"$BUILD_JOBS"

FIRMWARE_DIR="$BASE_PATH/../firmware"
\rm -rf "$FIRMWARE_DIR"
mkdir -p "$FIRMWARE_DIR"
find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
find "$TARGET_DIR" -type f \( -name "profiles.json" -o -name "sha256sums" -o -name "config.buildinfo" -o -name "feeds.buildinfo" -o -name "version.buildinfo" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
\rm -f "$BASE_PATH/../firmware/Packages.manifest" 2>/dev/null

validate_build_state "$source_dir"
BUILD_STATE_FILE="$source_dir/.wrt-release-build-state"
WRT_RELEASE_COMMIT=$(build_state_value "$BUILD_STATE_FILE" "WrtReleaseCommit")
WRT_RELEASE_TREE_STATE=$(build_state_value "$BUILD_STATE_FILE" "WrtReleaseTreeState")
WRT_RELEASE_INPUT_SHA256=$(build_state_value "$BUILD_STATE_FILE" "WrtReleaseInputSha256")
SOURCE_COMMIT=$(build_state_value "$BUILD_STATE_FILE" "SourceCommit")
SOURCE_LOCKS_SHA256=$(build_state_value "$BUILD_STATE_FILE" "SourceLocksSha256")
CONFIG_SHA256=$(build_state_value "$BUILD_STATE_FILE" "ConfigSha256")
PREPARED_SOURCE_SHA256=$(build_state_value "$BUILD_STATE_FILE" "PreparedSourceSha256")
APK_BUILD_PUBLIC_KEY_SHA256=$(build_state_value "$BUILD_STATE_FILE" "ApkBuildPublicKeySha256")
BUILD_CONTAINER_BASE=$(build_state_value "$BUILD_STATE_FILE" "BuildContainerBase")
BUILD_CONTAINER_IMAGE_ID=$(build_state_value "$BUILD_STATE_FILE" "BuildContainerImageId")
KERNEL_PATCHVER=$(sed -n 's/^KERNEL_PATCHVER:=[[:space:]]*//p' \
    "$BASE_PATH/../$BUILD_DIR/target/linux/qualcommax/Makefile" | head -n 1)
KERNEL_SUFFIX=$(sed -n "s/^LINUX_VERSION-${KERNEL_PATCHVER}[[:space:]]*=[[:space:]]*//p" \
    "$BASE_PATH/../$BUILD_DIR/target/linux/generic/kernel-${KERNEL_PATCHVER}" | head -n 1)
cat >"$FIRMWARE_DIR/BUILD_PROVENANCE.txt" <<EOF
Device: $Dev
WrtReleaseCommit: $WRT_RELEASE_COMMIT
WrtReleaseTreeState: $WRT_RELEASE_TREE_STATE
WrtReleaseInputSha256: $WRT_RELEASE_INPUT_SHA256
SourceUrl: $REPO_URL
SourceBranch: $REPO_BRANCH
SourceCommit: $SOURCE_COMMIT
SourceLocksSha256: $SOURCE_LOCKS_SHA256
BuildContainerBase: $BUILD_CONTAINER_BASE
BuildContainerImageId: $BUILD_CONTAINER_IMAGE_ID
ConfigSha256: $CONFIG_SHA256
PreparedSourceSha256: $PREPARED_SOURCE_SHA256
ApkBuildPublicKeySha256: $APK_BUILD_PUBLIC_KEY_SHA256
Kernel: ${KERNEL_PATCHVER}${KERNEL_SUFFIX}
ConfigFragments: $(join_fragments "${EFFECTIVE_CONFIG_FRAGMENTS[@]}")
DownloadJobs: $DOWNLOAD_JOBS
BuildJobs: $BUILD_JOBS
EOF

(
    cd "$FIRMWARE_DIR"
    mapfile -d '' firmware_files < <(find . -maxdepth 1 -type f ! -name "SHA256SUMS" -printf '%P\0' | sort -z)
    sha256sum "${firmware_files[@]}" >SHA256SUMS
)

verify_profile_artifacts "$Dev" "$FIRMWARE_DIR" "$BASE_PATH/../$BUILD_DIR"

if [[ -d action_build ]]; then
    make clean
fi
