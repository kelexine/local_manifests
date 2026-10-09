#!/usr/bin/env bash
#
# File: setup.sh
# Author: kelexine <https://github.com/kelexine>
# SPDX-FileCopyrightText: 2026 kelexine
# SPDX-License-Identifier: Apache-2.0
#
# Usage: ./setup.sh <rom> [branch] [workspace_dir]
# Run ./setup.sh --help for details.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "${0}")"
readonly LOCAL_MANIFESTS_REPO="https://github.com/kelexine/local_manifests"
readonly TOTAL_CORES="$(nproc 2>/dev/null || echo 4)"
readonly REPO_SYNC_JOBS="$(( TOTAL_CORES > 16 ? 16 : TOTAL_CORES ))"

declare -A ROM_DEFAULT_BRANCH=(
    [lineage]="23.2"
    [axion]="2.9"
    [twrp]="12.1"
)

declare -A ROM_UPSTREAM_URL=(
    [lineage]="https://github.com/LineageOS/android"
    [axion]="https://github.com/AxionAOSP/android"
    [twrp]="https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp"
)

# rom:branch -> upstream manifest branch name
declare -A ROM_UPSTREAM_BRANCH=(
    [lineage:23.2]="lineage-23.2"
    [lineage:19.1]="lineage-19.1"
    [axion:2.9]="lineage-23.2"
    [axion:2.8]="lineage-23.2"
    [twrp:12.1]="twrp-12.1"
)

# rom:branch -> local_manifests xml filename (no extension)
declare -A LOCAL_MANIFEST_FILE=(
    [lineage:23.2]="lineage-23.2"
    [lineage:19.1]="lineage-19.1"
    [axion:2.9]="axion-2.9"
    [axion:2.8]="axion-2.8"
    [twrp:12.1]="twrp-12.1"
)

log()   { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

download_ndk() {
    local ndk_version="r29"
    local ndk_zip="android-ndk-${ndk_version}-linux.zip"
    local ndk_url="https://dl.google.com/android/repository/${ndk_zip}"
    local ndk_dir="${HOME}/Android/Ndk/android-ndk-${ndk_version}"

    if [[ -d "${ndk_dir}" ]]; then
        log "NDK ${ndk_version} already installed at ${ndk_dir}"
        return 0
    fi

    log "Downloading NDK ${ndk_version}..."
    mkdir -p "${HOME}/Android/Ndk"
    if ! curl -L -o "${HOME}/Android/Ndk/${ndk_zip}" "${ndk_url}"; then
        error "Failed to download NDK from ${ndk_url}"
        return 1
    fi

    log "Extracting NDK..."
    if ! unzip -q "${HOME}/Android/Ndk/${ndk_zip}" -d "${HOME}/Android/Ndk"; then
        error "Failed to extract NDK"
        return 1
    fi
    rm -f "${HOME}/Android/Ndk/${ndk_zip}"

    log "NDK ${ndk_version} installed at ${ndk_dir}"
}

configure_ndk_env() {
    local ndk_version="r29"
    local ndk_dir="${HOME}/Android/Ndk/android-ndk-${ndk_version}"
    local env_script="${WORKSPACE_DIR}/kernel-env.sh"

    log "Configuring kernel build environment in ${env_script}..."
    cat <<EOF > "${env_script}"
#!/usr/bin/env bash
# Kernel build environment using Android NDK ${ndk_version}
export NDK_HOME="${ndk_dir}"
export PATH="${ndk_dir}/toolchains/llvm/prebuilt/linux-x86_64/bin:\${PATH}"
export TARGET_KERNEL_CLANG_PATH="${ndk_dir}/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CLANG_TRIPLE="aarch64-linux-gnu-"
export CROSS_COMPILE="aarch64-linux-gnu-"
export LLVM=1
export LLVM_IAS=1
EOF
    chmod +x "${env_script}"
    log "Environment script created: ${env_script}"
}

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} <rom> [branch] [workspace_dir]

Supported ROMs and their default branches:
$(for rom in "${!ROM_DEFAULT_BRANCH[@]}"; do printf '  %-10s default branch: %s\n' "${rom}" "${ROM_DEFAULT_BRANCH[${rom}]}"; done | sort)

Supported branches per ROM:
$(for key in "${!LOCAL_MANIFEST_FILE[@]}"; do printf '  %s\n' "${key}"; done | sort)

Examples:
  ${SCRIPT_NAME} lineage
  ${SCRIPT_NAME} lineage 19.1
  ${SCRIPT_NAME} axion
  ${SCRIPT_NAME} axion 2.8 ~/rom/axion
  ${SCRIPT_NAME} twrp

Options:
  -h, --help    Show this help message and exit.
EOF
}

require_command() {
    command -v "${1}" >/dev/null 2>&1 || die "Required command '${1}' not found in PATH. Please install it first."
}

if [[ $# -eq 0 ]] || [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
    usage
    exit 0
fi

readonly ROM="${1}"
shift || true

BRANCH="${1:-}"
if [[ -n "${BRANCH:-}" && ! "${BRANCH}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "Invalid branch '${BRANCH}'."
fi
[[ $# -gt 0 ]] && shift || true

WORKSPACE_DIR="${1:-${PWD}/${ROM}}"
[[ $# -gt 0 ]] && shift || true

if [[ -z "${ROM_DEFAULT_BRANCH[${ROM}]+set}" ]]; then
    die "Unknown ROM '${ROM}'. Supported: ${!ROM_DEFAULT_BRANCH[*]}"
fi

if [[ -z "${BRANCH}" ]]; then
    BRANCH="${ROM_DEFAULT_BRANCH[${ROM}]}"
    log "No branch specified, defaulting to '${BRANCH}' for '${ROM}'."
fi

readonly ROM_BRANCH_KEY="${ROM}:${BRANCH}"

if [[ -z "${ROM_UPSTREAM_BRANCH[${ROM_BRANCH_KEY}]+set}" ]]; then
    die "Unsupported branch '${BRANCH}' for ROM '${ROM}'. Run '${SCRIPT_NAME} --help' to see supported combinations."
fi

if [[ -z "${LOCAL_MANIFEST_FILE[${ROM_BRANCH_KEY}]+set}" ]]; then
    die "Internal error: no local manifest mapping for '${ROM_BRANCH_KEY}'."
fi

readonly UPSTREAM_URL="${ROM_UPSTREAM_URL[${ROM}]}"
readonly UPSTREAM_BRANCH="${ROM_UPSTREAM_BRANCH[${ROM_BRANCH_KEY}]}"
readonly LOCAL_MANIFEST_XML="${LOCAL_MANIFEST_FILE[${ROM_BRANCH_KEY}]}.xml"

require_command git
require_command repo
require_command curl
require_command unzip

log "ROM:              ${ROM}"
log "Branch:           ${BRANCH}"
log "Upstream manifest: ${UPSTREAM_URL} (${UPSTREAM_BRANCH})"
log "Local manifest:   ${LOCAL_MANIFEST_XML}"
log "Workspace:        ${WORKSPACE_DIR}"

mkdir -p "${WORKSPACE_DIR}"
cd "${WORKSPACE_DIR}"

if [[ -d .repo ]]; then
    log ".repo already exists in ${WORKSPACE_DIR}; re-running repo init to update manifest settings."
else
    log "Initializing new repo workspace."
fi

repo init -u "${UPSTREAM_URL}" -b "${UPSTREAM_BRANCH}" --git-lfs

readonly LOCAL_MANIFESTS_DIR=".repo/local_manifests"

if [[ -d "${LOCAL_MANIFESTS_DIR}/.git" ]]; then
    log "local_manifests already cloned; fetching latest main."
    git -C "${LOCAL_MANIFESTS_DIR}" fetch origin main
    git -C "${LOCAL_MANIFESTS_DIR}" checkout main
    git -C "${LOCAL_MANIFESTS_DIR}" reset --hard origin/main
else
    rm -rf "${LOCAL_MANIFESTS_DIR}"
    log "Cloning local_manifests (main)."
    git clone -b main "${LOCAL_MANIFESTS_REPO}" "${LOCAL_MANIFESTS_DIR}"
fi

if [[ ! -f "${LOCAL_MANIFESTS_DIR}/${LOCAL_MANIFEST_XML}" ]]; then
    die "Expected manifest '${LOCAL_MANIFEST_XML}' not found in local_manifests repo."
fi

log "Clearing previously-selected manifest XML files."
find "${LOCAL_MANIFESTS_DIR}" -maxdepth 1 -name '*.xml' ! -name "${LOCAL_MANIFEST_XML}" -exec rm -f {} +

log "Selecting manifest: ${LOCAL_MANIFEST_XML}"
if [[ "${LOCAL_MANIFEST_XML}" != "${ROM}.xml" ]]; then
    mv -f "${LOCAL_MANIFESTS_DIR}/${LOCAL_MANIFEST_XML}" "${LOCAL_MANIFESTS_DIR}/${ROM}.xml"
fi

log "Starting repo sync with ${REPO_SYNC_JOBS} jobs. This will take a while."
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune -j"${REPO_SYNC_JOBS}"
download_ndk
configure_ndk_env

if [[ -f "${LOCAL_MANIFESTS_DIR}/build-${ROM}.sh" ]]; then
    log "Installing build script: build-${ROM}.sh -> ${WORKSPACE_DIR}/build.sh"
    cp -f "${LOCAL_MANIFESTS_DIR}/build-${ROM}.sh" "${WORKSPACE_DIR}/build.sh"
    chmod +x "${WORKSPACE_DIR}/build.sh"
fi

log "Done. Workspace ready at: ${WORKSPACE_DIR}"
log "Next: cd ${WORKSPACE_DIR} && ./build.sh [userdebug|user|eng]"
