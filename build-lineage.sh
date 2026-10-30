#!/usr/bin/env bash
# Script: build-lineage.sh
# Author: kelexine <https://github.com/kelexine>
# Date: 2026-10-13
# Purpose: Automated LineageOS ROM build script for Cubot P50 (marlon/lineage-23.2 branch)
#          with inline kernel and in-tree MTK connectivity/MET modules compilation.
# Usage: ./build-lineage.sh [userdebug|user|eng]

set -eo pipefail

# --- Configuration & Paths ---
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/build/envsetup.sh" ]]; then
    readonly WORKSPACE_ROOT="${SCRIPT_DIR}"
elif [[ -f "${SCRIPT_DIR}/../../build/envsetup.sh" ]]; then
    readonly WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
elif [[ -f "$(pwd)/build/envsetup.sh" ]]; then
    readonly WORKSPACE_ROOT="$(pwd)"
else
    readonly WORKSPACE_ROOT="${SCRIPT_DIR}"
fi
readonly DEVICE="marlon"
TARGET_VARIANT="userdebug"
JOB_COUNT=""
KERNEL_ONLY=false
AUTO_RELEASE=false

readonly KERNEL_SRC="${WORKSPACE_ROOT}/kernel/cubot/${DEVICE}"

readonly NDK_DIR="${HOME}/Android/Ndk/android-ndk-r29"
readonly NDK_BIN="${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin"

readonly LOG_DIR="${WORKSPACE_ROOT}/logs"
readonly SCRIPT_BASE="$(basename "${0}" .sh)"
readonly LOG_TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_BASE}_${LOG_TIMESTAMP}.log"
readonly LATEST_LOG="${LOG_DIR}/${SCRIPT_BASE}_latest.log"
readonly ROOT_LOG="${WORKSPACE_ROOT}/build.log"

log()   { printf '\033[1;32m[build-lineage]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[build-lineage]\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m[build-lineage]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

show_help() {
    cat <<'EOF'
LineageOS Build Script for Cubot P50 (marlon)

Usage:
  ./build-lineage.sh [variant] [options]

Arguments:
  variant                         Target variant: userdebug (default), user, eng

Options:
  -j, -j<N>, --jobs <N>           Parallel make/ninja job count
  --kernel-only, -k               Compile inline kernel, dtbs, and in-tree modules only
  --release, -r                   Push completed build artifacts to GitHub Release via push-release.sh
  -h, --help                      Show this help message
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            userdebug|user|eng)
                TARGET_VARIANT="$1"
                ;;
            -j|--jobs)
                [[ -n "${2:-}" ]] || die "Option $1 requires an integer argument."
                JOB_COUNT="$2"
                shift
                ;;
            -j*)
                JOB_COUNT="${1#-j}"
                ;;
            --kernel-only|-k)
                KERNEL_ONLY=true
                ;;
            --release|-r)
                AUTO_RELEASE=true
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                warn "Unknown argument '$1' (ignored)"
                ;;
        esac
        shift
    done
}

setup_logging() {
    mkdir -p "${LOG_DIR}"
    touch "${LOG_FILE}"
    ln -sfn "$(basename "${LOG_FILE}")" "${LATEST_LOG}" 2>/dev/null || true
    ln -sfn "logs/$(basename "${LOG_FILE}")" "${ROOT_LOG}" 2>/dev/null || true

    log "Logging build output to: ${LOG_FILE} (symlink: ${ROOT_LOG})"

    exec 3>&1 4>&2
    exec > >(tee -a "${LOG_FILE}") 2>&1
    trap 'local_exit_status=$?; exec 1>&3 2>&4; wait; exit ${local_exit_status}' EXIT
}

format_duration() {
    local total_secs=$1
    local mins=$((total_secs / 60))
    local secs=$((total_secs % 60))
    if (( mins > 0 )); then
        printf "%dm %02ds (%ds)" "${mins}" "${secs}" "${total_secs}"
    else
        printf "%ds" "${total_secs}"
    fi
}

verify_prerequisites() {
    log "Verifying build prerequisites..."
    [[ -d "${NDK_BIN}" ]] || die "NDK r29 toolchain not found at ${NDK_BIN}. Please run setup.sh first."
    [[ -f "${WORKSPACE_ROOT}/build/envsetup.sh" ]] || die "Workspace root is not an Android build tree (${WORKSPACE_ROOT})."
    [[ -d "${KERNEL_SRC}" ]] || die "Kernel source missing at ${KERNEL_SRC}."
}

setup_kernel_toolchain_env() {
    log "Configuring Android NDK r29 LLVM environment for kernel compilation..."
    export PATH="${NDK_BIN}:${PATH}"
    # BoardConfigKernel.mk appends /bin/clang to this path, so point to
    # the parent of bin/ (linux-x86_64), not bin/ itself — else we get /bin/bin/clang.
    export TARGET_KERNEL_CLANG_PATH="${NDK_BIN%/bin}"
    export CLANG_TRIPLE="aarch64-linux-gnu-"
    export CROSS_COMPILE="aarch64-linux-gnu-"
    export LLVM=1
    export LLVM_IAS=1
    export ARCH="arm64"
    export CC="clang"
    export LD="ld.lld"
    export AR="llvm-ar"
    export NM="llvm-nm"
    export OBJCOPY="llvm-objcopy"
    export OBJDUMP="llvm-objdump"
    export STRIP="llvm-strip"
    export KCFLAGS="-Wno-unused-command-line-argument"
    export CFLAGS="-Wno-unused-command-line-argument"
    export CFLAGS_MODULE="-Wno-unused-command-line-argument"
}

init_android_environment() {
    log "Initializing AOSP / LineageOS build environment..."
    cd "${WORKSPACE_ROOT}"
    export ANDROID_BUILD_TOP="${WORKSPACE_ROOT}"
    export ANDROID_KEY_PATH="${WORKSPACE_ROOT}/vendor/lineage-priv/keys"

    # Purge any conflicting manifests in .repo/local_manifests to ensure build-manifest.xml succeeds
    if [[ -d "${WORKSPACE_ROOT}/.repo/local_manifests" ]]; then
        find "${WORKSPACE_ROOT}/.repo/local_manifests" -maxdepth 1 -name '*.xml' ! -name 'lineage.xml' ! -name 'lineage-*.xml' -exec rm -f {} +
    fi

    set +e
    # shellcheck source=/dev/null
    source build/envsetup.sh
    set -e

    local target_release="bp4a"
    if [[ -f "${WORKSPACE_ROOT}/vendor/lineage/vars/aosp_target_release" ]]; then
        # shellcheck source=/dev/null
        source "${WORKSPACE_ROOT}/vendor/lineage/vars/aosp_target_release"
        target_release="${aosp_target_release:-bp4a}"
    fi

    local lunch_combo="lineage_${DEVICE}-${target_release}-${TARGET_VARIANT}"
    log "Selecting lunch target: ${lunch_combo}..."
    lunch "${lunch_combo}" || die "Failed to lunch ${lunch_combo}."
}

build_inline_kernel() {
    log "Building inline kernel and dtbs via mka..."
    mka kernel dtboimage || die "Kernel compilation failed."
}

build_rom_package() {
    local jobs_arg=()
    [[ -n "${JOB_COUNT}" ]] && jobs_arg+=("-j${JOB_COUNT}")

    log "Starting LineageOS ROM packaging (mka bacon ${jobs_arg[*]:-})..."
    mka bacon "${jobs_arg[@]}" || die "LineageOS packaging failed."
    log "[+] Build completed successfully!"
    log "[+] Output images located at: ${OUT}"

    local pub_dir="/var/www/html/kelexine"
    if [[ -d "/var/www/html" && -w "/var/www/html" ]] || [[ -w "${pub_dir}" ]]; then
        mkdir -p "${pub_dir}" 2>/dev/null || true
        if compgen -G "${OUT}/lineage_*.zip" > /dev/null; then
            cp -v "${OUT}"/lineage_*.zip "${pub_dir}/" 2>/dev/null || true
            log "[+] Published ROM zip: https://ferrari.serverhive.in/kelexine/"
        fi
    fi

    if [[ "${AUTO_RELEASE}" == "true" ]]; then
        local push_script=""
        if [[ -x "${WORKSPACE_ROOT}/push-release.sh" ]]; then
            push_script="${WORKSPACE_ROOT}/push-release.sh"
        elif [[ -x "${SCRIPT_DIR}/push-release.sh" ]]; then
            push_script="${SCRIPT_DIR}/push-release.sh"
        elif [[ -x "${WORKSPACE_ROOT}/.repo/local_manifests/push-release.sh" ]]; then
            push_script="${WORKSPACE_ROOT}/.repo/local_manifests/push-release.sh"
        elif command -v push-release.sh >/dev/null 2>&1; then
            push_script="$(command -v push-release.sh)"
        fi

        local out_target="${OUT:-${ANDROID_PRODUCT_OUT:-${WORKSPACE_ROOT}/out/target/product/${DEVICE}}}"
        if [[ -n "${push_script}" ]]; then
            log "Triggering automatic GitHub release push via ${push_script}..."
            "${push_script}" "${out_target}" || warn "Release upload failed or was skipped."
        else
            warn "Automatic release requested (-r/--release), but push-release.sh was not found or is not executable!"
        fi
    else
        log "[*] To publish this build to GitHub Releases, run:"
        log "    ./push-release.sh ${OUT:-out/target/product/${DEVICE}}"
    fi
}

main() {
    parse_arguments "$@"
    setup_logging
    local start_time
    start_time="$(date +%s)"

    verify_prerequisites
    setup_kernel_toolchain_env
    init_android_environment

    if [[ "${KERNEL_ONLY}" == "true" ]]; then
        build_inline_kernel
        log "[+] Kernel and modules built successfully (--kernel-only specified)."
    else
        build_rom_package
    fi

    local end_time
    end_time="$(date +%s)"
    log "[+] Total build time: $(format_duration $((end_time - start_time)))"
    log "[+] Build log saved to: ${LOG_FILE}"
}

main "$@"
