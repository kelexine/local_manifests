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
readonly REPO_SYNC_JOBS="${REPO_SYNC_JOBS:-$(( TOTAL_CORES > 32 ? 32 : TOTAL_CORES ))}"

declare -A ROM_DEFAULT_BRANCH=(
    [lineage]="23.2"
    [axion]="axion"
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
    [lineage:lineage-23.2]="lineage-23.2"
    [lineage:19.1]="lineage-19.1"
    [lineage:lineage-19.1]="lineage-19.1"
    [axion:axion]="lineage-23.2"
    [axion:23.2]="lineage-23.2"
    [axion:lineage-23.2]="lineage-23.2"
    [twrp:12.1]="twrp-12.1"
    [twrp:twrp-12.1]="twrp-12.1"
    [twrp:twrp]="twrp-12.1"
)

# rom:branch -> local_manifests xml filename (no extension)
declare -A LOCAL_MANIFEST_FILE=(
    [lineage:23.2]="lineage-23.2"
    [lineage:lineage-23.2]="lineage-23.2"
    [lineage:19.1]="lineage-19.1"
    [lineage:lineage-19.1]="lineage-19.1"
    [axion:axion]="axion"
    [axion:23.2]="axion"
    [axion:lineage-23.2]="axion"
    [twrp:12.1]="twrp-12.1"
    [twrp:twrp-12.1]="twrp-12.1"
    [twrp:twrp]="twrp-12.1"
)

log()   { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m[setup]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

setup_logging() {
    local log_dir="${WORKSPACE_DIR}/logs"
    local timestamp="$(date +'%Y%m%d_%H%M%S')"
    local log_file="${log_dir}/setup_${ROM}_${timestamp}.log"
    local latest_log="${log_dir}/setup_${ROM}_latest.log"
    local root_log="${WORKSPACE_DIR}/setup.log"

    mkdir -p "${log_dir}"
    touch "${log_file}"
    ln -sfn "$(basename "${log_file}")" "${latest_log}" 2>/dev/null || true
    ln -sfn "logs/$(basename "${log_file}")" "${root_log}" 2>/dev/null || true

    log "Logging setup output to: ${log_file} (symlink: ${root_log})"

    exec 3>&1 4>&2
    exec > >(tee -a "${log_file}") 2>&1
    trap 'local_exit_status=$?; exec 1>&3 2>&4; wait; exit ${local_exit_status}' EXIT
}

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

configure_signing_keys() {
    local keys_dir="${WORKSPACE_DIR}/vendor/lineage-priv/keys"
    local external_certs="${HOME}/android-certs"

    if [[ ! -d "${keys_dir}" && -d "${external_certs}" ]]; then
        log "Staging signing keys from ${external_certs} into ${keys_dir}..."
        mkdir -p "${keys_dir}"
        cp -a "${external_certs}/"* "${keys_dir}/"
    fi

    if [[ -d "${keys_dir}" ]]; then
        log "Ensuring signing keys configuration exists in ${keys_dir}..."
        cat <<'EOF' > "${keys_dir}/keys.mk"
PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey
PRODUCT_MAINLINE_SEPOLICY_DEV_CERTIFICATES := $(dir $(PRODUCT_DEFAULT_DEV_CERTIFICATE))
PRODUCT_MAINLINE_BLUETOOTH_SEPOLICY_DEV_CERTIFICATES := $(dir $(PRODUCT_DEFAULT_DEV_CERTIFICATE))
EOF
        cat <<'EOF' > "${keys_dir}/BUILD.bazel"
filegroup(
    name = "android_certificate_directory",
    srcs = glob([
        "*.pk8",
        "*.pem",
    ]),
    visibility = ["//visibility:public"],
)
EOF
        log "Signing keys configured: ${keys_dir}/keys.mk and BUILD.bazel"
    fi
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
  ${SCRIPT_NAME} axion axion ~/rom/axion
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

BRANCH=""
WORKSPACE_DIR=""

if [[ $# -gt 0 ]]; then
    # If the next argument looks like a path (contains '/'), treat it as WORKSPACE_DIR
    if [[ "${1}" == */* ]]; then
        WORKSPACE_DIR="${1}"
        shift || true
    else
        # Strip optional "<rom>:" prefix if user passed e.g. "twrp:12.1"
        BRANCH="${1#${ROM}:}"
        if [[ -n "${BRANCH}" && ! "${BRANCH}" =~ ^[A-Za-z0-9._-]+$ ]]; then
            die "Invalid branch '${1}'."
        fi
        shift || true
    fi
fi

if [[ -z "${WORKSPACE_DIR}" ]]; then
    WORKSPACE_DIR="${1:-${PWD}/${ROM}}"
    [[ $# -gt 0 ]] && shift || true
fi

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
setup_logging

if [[ -d .repo ]]; then
    log ".repo already exists in ${WORKSPACE_DIR}; re-running repo init to update manifest settings."
else
    log "Initializing new repo workspace."
fi

repo init -u "${UPSTREAM_URL}" -b "${UPSTREAM_BRANCH}" --git-lfs

readonly LOCAL_MANIFESTS_DIR=".repo/local_manifests"
readonly LOCAL_MANIFESTS_CACHE=".repo/.local_manifests_repo"

# Migrate legacy setups where .repo/local_manifests was itself the git clone
if [[ -d "${LOCAL_MANIFESTS_DIR}/.git" ]]; then
    log "Migrating legacy .repo/local_manifests git clone to cache directory."
    rm -rf "${LOCAL_MANIFESTS_CACHE}"
    mv -f "${LOCAL_MANIFESTS_DIR}" "${LOCAL_MANIFESTS_CACHE}"
fi

if [[ -d "${LOCAL_MANIFESTS_CACHE}/.git" ]]; then
    log "local_manifests repo already cloned; fetching latest main."
    git -C "${LOCAL_MANIFESTS_CACHE}" fetch origin main
    git -C "${LOCAL_MANIFESTS_CACHE}" checkout main
    git -C "${LOCAL_MANIFESTS_CACHE}" reset --hard origin/main
else
    rm -rf "${LOCAL_MANIFESTS_CACHE}"
    log "Cloning local_manifests (main) to cache."
    git clone -b main "${LOCAL_MANIFESTS_REPO}" "${LOCAL_MANIFESTS_CACHE}"
fi

if [[ ! -f "${LOCAL_MANIFESTS_CACHE}/${LOCAL_MANIFEST_XML}" ]]; then
    die "Expected manifest '${LOCAL_MANIFEST_XML}' not found in local_manifests repo."
fi

mkdir -p "${LOCAL_MANIFESTS_DIR}"

log "Clearing previously-selected manifest XML files in ${LOCAL_MANIFESTS_DIR}."
find "${LOCAL_MANIFESTS_DIR}" -maxdepth 1 -name '*.xml' -exec rm -f {} +

log "Installing manifest: ${LOCAL_MANIFEST_XML} -> ${LOCAL_MANIFESTS_DIR}/${ROM}.xml"
cp -f "${LOCAL_MANIFESTS_CACHE}/${LOCAL_MANIFEST_XML}" "${LOCAL_MANIFESTS_DIR}/${ROM}.xml"

log "Starting repo sync with ${REPO_SYNC_JOBS} jobs. This will take a while."
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune -j"${REPO_SYNC_JOBS}"

if [[ -d "${WORKSPACE_DIR}/kernel/cubot/marlon" ]]; then
    log "Initializing kernel submodules (MySU)..."
    git -C "${WORKSPACE_DIR}/kernel/cubot/marlon" submodule update --init --recursive || true
    download_ndk
    configure_ndk_env
elif [[ "${ROM}" != "twrp" ]]; then
    download_ndk
    configure_ndk_env
fi

if [[ "${ROM}" != "twrp" ]]; then
    configure_signing_keys
fi

if [[ -f "${LOCAL_MANIFESTS_CACHE}/build-${ROM}.sh" ]]; then
    log "Installing build script: build-${ROM}.sh -> ${WORKSPACE_DIR}/build.sh"
    cp -f "${LOCAL_MANIFESTS_CACHE}/build-${ROM}.sh" "${WORKSPACE_DIR}/build.sh"
    chmod +x "${WORKSPACE_DIR}/build.sh"
fi

log "Done. Workspace ready at: ${WORKSPACE_DIR}"
log "Setup log saved to: ${WORKSPACE_DIR}/setup.log"
if [[ "${ROM}" == "twrp" ]]; then
    log "Next: cd ${WORKSPACE_DIR} && ./build.sh [eng|userdebug|user]"
else
    log "Next: cd ${WORKSPACE_DIR} && ./build.sh [userdebug|user|eng]"
fi
