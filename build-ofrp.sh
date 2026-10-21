#!/usr/bin/env bash
# Script: build-ofrp.sh
# Author: kelexine <https://github.com/kelexine>
# Date: 2026-10-21
# Purpose: Automated OrangeFox Recovery Project 12.1 build script for Cubot P50 (marlon)
# Usage: ./build-ofrp.sh [eng|userdebug|user] [-j<num>] [--inline-kernel]

set -eo pipefail

# --- Configuration & Paths ---
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKSPACE_ROOT="${SCRIPT_DIR}"
readonly DEVICE="marlon"

TARGET_VARIANT="eng"
JOB_COUNT=""
INLINE_KERNEL=false

readonly DEVICE_TREE_DIR="${WORKSPACE_ROOT}/device/cubot/${DEVICE}"
readonly KERNEL_SRC="${WORKSPACE_ROOT}/kernel/cubot/${DEVICE}"
readonly NDK_DIR="${HOME}/Android/Ndk/android-ndk-r29"
readonly NDK_BIN="${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin"

readonly LOG_DIR="${WORKSPACE_ROOT}/logs"
readonly SCRIPT_BASE="$(basename "${0}" .sh)"
readonly LOG_TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_BASE}_${LOG_TIMESTAMP}.log"
readonly LATEST_LOG="${LOG_DIR}/${SCRIPT_BASE}_latest.log"
readonly ROOT_LOG="${WORKSPACE_ROOT}/build.log"

log()   { printf '\033[1;35m[build-ofrp]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[build-ofrp]\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m[build-ofrp]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

show_help() {
    cat <<'EOF'
OrangeFox Recovery Project 12.1 Build Script for Cubot P50 (marlon)

Usage: ./build-ofrp.sh [variant] [options]

Build Variants:
  eng | userdebug | user          (default: eng)

Options:
  -j<num>                         Job count (e.g. -j16, -j64)
  --inline-kernel                 Compile kernel from kernel/cubot/marlon with NDK r29
  -h, --help                      Show this help message and exit

Examples:
  ./build-ofrp.sh
  ./build-ofrp.sh eng -j64
  ./build-ofrp.sh eng --inline-kernel
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            eng|userdebug|user)
                TARGET_VARIANT="$1"
                ;;
            -j*)
                if [[ "$1" == "-j" ]]; then
                    shift
                    JOB_COUNT="${1:-}"
                else
                    JOB_COUNT="${1#-j}"
                fi
                ;;
            --inline-kernel)
                INLINE_KERNEL=true
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
    log "Verifying OrangeFox build prerequisites..."
    [[ -f "${WORKSPACE_ROOT}/build/envsetup.sh" ]] || die "Workspace root is not an Android/OFRP tree (${WORKSPACE_ROOT})."
    [[ -d "${DEVICE_TREE_DIR}" ]] || die "OrangeFox device tree missing at ${DEVICE_TREE_DIR}."
    if [[ "${INLINE_KERNEL}" == "true" ]]; then
        [[ -d "${KERNEL_SRC}" ]] || die "--inline-kernel requested, but kernel source missing at ${KERNEL_SRC}."
        [[ -d "${NDK_BIN}" ]] || die "--inline-kernel requested, but NDK r29 toolchain not found at ${NDK_BIN}."
    fi
}

setup_inline_kernel_env() {
    if [[ "${INLINE_KERNEL}" != "true" ]]; then
        return 0
    fi
    log "Configuring Android NDK r29 LLVM environment for inline kernel compilation..."
    export PATH="${NDK_BIN}:${PATH}"
    export TARGET_KERNEL_CLANG_PATH="${NDK_BIN%/bin}"
    export TARGET_FORCE_PREBUILT_KERNEL="false"
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
}

init_ofrp_environment() {
    log "Initializing OrangeFox 12.1 build environment..."
    cd "${WORKSPACE_ROOT}"
    export ANDROID_BUILD_TOP="${WORKSPACE_ROOT}"
    export FOX_BUILD_DEVICE="${DEVICE}"
    export ALLOW_MISSING_DEPENDENCIES=true
    export LC_ALL="C"

    if [[ -d "${WORKSPACE_ROOT}/.repo/local_manifests" ]]; then
        find "${WORKSPACE_ROOT}/.repo/local_manifests" -maxdepth 1 -name '*.xml' ! -name 'ofrp.xml' ! -name 'ofrp-*.xml' -exec rm -f {} +
    fi

    set +e
    # shellcheck source=/dev/null
    source build/envsetup.sh
    set -e

    local lunch_combo="ofox_${DEVICE}-${TARGET_VARIANT}"
    log "Selecting lunch target: ${lunch_combo}..."
    lunch "${lunch_combo}" || die "Failed to lunch ${lunch_combo}."
}

build_recovery_image() {
    local -a job_args=("-j$(nproc)")
    if [[ -n "${JOB_COUNT}" ]]; then
        job_args=("-j${JOB_COUNT}")
    fi

    log "Building OrangeFox recovery image (mka adbd recoveryimage ${job_args[*]})..."
    mka adbd recoveryimage "${job_args[@]}" || die "OrangeFox recoveryimage build failed."

    local recovery_img="${OUT}/recovery.img"
    [[ -f "${recovery_img}" ]] || die "Expected output ${recovery_img} not found after build."
    log "[+] OrangeFox recovery image built successfully: ${recovery_img}"

    local pub_dir="/var/www/html/kelexine"
    if [[ -d "/var/www/html" ]]; then
        mkdir -p "${pub_dir}"
        local dated_img="${pub_dir}/OrangeFox-12.1-${LOG_TIMESTAMP}-${DEVICE}.img"
        cp -v "${recovery_img}" "${dated_img}" || true
        ln -sfn "$(basename "${dated_img}")" "${pub_dir}/OrangeFox-${DEVICE}-latest.img" 2>/dev/null || true
        log "[+] Published OrangeFox recovery image: https://ferrari.serverhive.in/kelexine/$(basename "${dated_img}")"

        # Check for flashable OrangeFox recovery zip
        local ofox_zip
        ofox_zip=$(find "${OUT}" -maxdepth 2 -type f -name "OrangeFox-*.zip" | head -n 1)
        if [[ -n "${ofox_zip}" && -f "${ofox_zip}" ]]; then
            local dated_zip="${pub_dir}/$(basename "${ofox_zip%.zip}")-${LOG_TIMESTAMP}.zip"
            cp -v "${ofox_zip}" "${dated_zip}" || true
            ln -sfn "$(basename "${dated_zip}")" "${pub_dir}/OrangeFox-${DEVICE}-latest.zip" 2>/dev/null || true
            log "[+] Published OrangeFox recovery zip: https://ferrari.serverhive.in/kelexine/$(basename "${dated_zip}")"
        fi
    fi
}

main() {
    parse_arguments "$@"
    setup_logging
    local start_time
    start_time="$(date +%s)"

    log "=================================================="
    log "  OrangeFox 12.1 Build Automation for Cubot P50 (marlon)"
    log "  Variant:       ${TARGET_VARIANT}"
    log "  Inline Kernel: ${INLINE_KERNEL}"
    [[ -n "${JOB_COUNT}" ]] && log "  Job Count:     ${JOB_COUNT}"
    log "  Log File:      ${LOG_FILE}"
    log "=================================================="

    verify_prerequisites
    setup_inline_kernel_env
    init_ofrp_environment
    build_recovery_image

    local end_time
    end_time="$(date +%s)"
    log "[+] Total build time: $(format_duration $((end_time - start_time)))"
    log "[+] Build log saved to: ${LOG_FILE}"
}

main "$@"
