#!/usr/bin/env bash
set -euo pipefail

workspace_root=${TAIYI_WORKSPACE_ROOT:-/home/ubuntu/workspaces}

if [[ ! -r /etc/os-release ]]; then
    echo "Error: /etc/os-release is unavailable." >&2
    exit 1
fi

. /etc/os-release
if [[ ${ID:-} != "ubuntu" || ${VERSION_ID:-} != "24.04" ]]; then
    echo "Error: this setup script is validated for Ubuntu 24.04; found ${PRETTY_NAME:-unknown}." >&2
    exit 1
fi

workspace_fstype=$(findmnt -n -o FSTYPE -T "$workspace_root" 2>/dev/null || true)
if [[ $workspace_fstype != "ext4" ]]; then
    echo "Error: $workspace_root must be on ext4; found '${workspace_fstype:-unknown}'." >&2
    exit 1
fi

cat <<'EOF'
This script installs the audited OpenWrt build dependencies from Ubuntu's
configured APT repositories. sudo will request your password interactively.
EOF

sudo -v
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential clang flex bison g++ g++-multilib gawk gcc-multilib \
    gettext git libncurses-dev libssl-dev libelf-dev zlib1g-dev \
    python3 python3-pyelftools python3-setuptools rsync unzip bzip2 \
    xz-utils file wget curl patch diffutils subversion swig time \
    xsltproc zstd device-tree-compiler ccache cmake ninja-build \
    pkgconf jq dos2unix libfuse-dev
sudo apt-get clean

mkdir -p "$workspace_root"

required_commands=(
    gcc g++ make git perl python3 rsync tar unzip bzip2 xz patch diff
    find awk sed grep flex bison gawk gettext pkg-config cmake ninja
    ccache flock file wget curl dtc
)
missing_commands=()
for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing_commands+=("$command_name")
    fi
done

if (( ${#missing_commands[@]} > 0 )); then
    printf 'Error: required commands are still missing: %s\n' "${missing_commands[*]}" >&2
    exit 1
fi

printf 'Taiyi WSL build dependencies are ready. Workspace: %s (%s)\n' \
    "$workspace_root" "$workspace_fstype"
