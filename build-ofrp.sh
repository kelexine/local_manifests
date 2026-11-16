#!/usr/bin/env bash
# Script: build-ofrp.sh
# Author: kelexine <https://github.com/kelexine>
# Date: 2026-10-21
# Purpose: Automated OrangeFox Recovery Project 12.1 build script for Cubot P50 (marlon)
# Usage: ./build-ofrp.sh [eng|userdebug|user] [-j<num>] [--prebuilt-kernel] [-r|--release]

set -eo pipefail

# --- Configuration & Paths ---
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKSPACE_ROOT="${SCRIPT_DIR}"
readonly DEVICE="marlon"

TARGET_VARIANT="eng"
JOB_COUNT=""
INLINE_KERNEL=true
INLINE_KERNEL_EXPLICIT=false
AUTO_RELEASE=false
RELEASE_TAG_OVERRIDE=""
RELEASE_PRERELEASE=false

readonly DEVICE_TREE_DIR="${WORKSPACE_ROOT}/device/cubot/${DEVICE}"
readonly KERNEL_SRC="${WORKSPACE_ROOT}/kernel/cubot/${DEVICE}"
readonly NDK_DIR="${HOME}/Android/Ndk/android-ndk-r30"
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
  --inline-kernel                 Compile kernel from kernel/cubot/marlon with NDK r30 (default)
  --prebuilt-kernel               Force stock prebuilt kernel fallback instead of building from source
  -r, --release                   Publish built recovery outputs to GitHub Releases via push-release.sh
      --tag <tag>                 Explicit release tag for --release (default: ofrp-12.1-YYYYMMDD)
      --prerelease                Mark GitHub Release as pre-release (used with --release)
  -h, --help                      Show this help message and exit

Examples:
  ./build-ofrp.sh
  ./build-ofrp.sh eng -j64
  ./build-ofrp.sh eng -j64 -r
  ./build-ofrp.sh eng --prebuilt-kernel
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
                INLINE_KERNEL_EXPLICIT=true
                ;;
            --prebuilt-kernel)
                INLINE_KERNEL=false
                ;;
            -r|--release)
                AUTO_RELEASE=true
                ;;
            --tag)
                shift
                RELEASE_TAG_OVERRIDE="${1:-}"
                [[ -n "${RELEASE_TAG_OVERRIDE}" ]] || die "--tag requires a value."
                ;;
            --tag=*)
                RELEASE_TAG_OVERRIDE="${1#--tag=}"
                [[ -n "${RELEASE_TAG_OVERRIDE}" ]] || die "--tag requires a value."
                ;;
            --prerelease)
                RELEASE_PRERELEASE=true
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

resolve_push_script() {
    if [[ -x "${WORKSPACE_ROOT}/push-release.sh" ]]; then
        echo "${WORKSPACE_ROOT}/push-release.sh"
    elif [[ -x "${SCRIPT_DIR}/push-release.sh" ]]; then
        echo "${SCRIPT_DIR}/push-release.sh"
    elif [[ -x "${WORKSPACE_ROOT}/.repo/.local_manifests_repo/push-release.sh" ]]; then
        echo "${WORKSPACE_ROOT}/.repo/.local_manifests_repo/push-release.sh"
    elif command -v push-release.sh >/dev/null 2>&1; then
        command -v push-release.sh
    fi
}

verify_prerequisites() {
    log "Verifying OrangeFox build prerequisites..."
    [[ -f "${WORKSPACE_ROOT}/build/envsetup.sh" ]] || die "Workspace root is not an Android/OFRP tree (${WORKSPACE_ROOT})."
    [[ -d "${DEVICE_TREE_DIR}" ]] || die "OrangeFox device tree missing at ${DEVICE_TREE_DIR}."
    if [[ "${INLINE_KERNEL}" == "true" ]]; then
        if [[ ! -d "${KERNEL_SRC}" ]]; then
            if [[ "${INLINE_KERNEL_EXPLICIT}" == "true" ]]; then
                die "--inline-kernel requested, but kernel source missing at ${KERNEL_SRC}."
            fi
            warn "Kernel source missing at ${KERNEL_SRC}; falling back to stock prebuilt kernel."
            INLINE_KERNEL=false
        elif [[ ! -d "${NDK_BIN}" ]]; then
            die "NDK r30 toolchain not found at ${NDK_BIN}. Please run setup.sh first."
        fi
    fi
}

setup_signing_keys() {
    local keys_dir="${WORKSPACE_ROOT}/vendor/lineage-priv/keys"
    local external_certs="${HOME}/android-certs"

    if [[ -f "${external_certs}/releasekey.pk8" && ! -f "${keys_dir}/releasekey.pk8" ]]; then
        log "Staging ROM signing keys from ${external_certs} -> ${keys_dir}..."
        mkdir -p "${keys_dir}"
        cp -af "${external_certs}"/*.pk8 "${external_certs}"/*.pem "${keys_dir}/"
        chmod 600 "${keys_dir}"/*.pk8 2>/dev/null || true
    fi

    if [[ -f "${keys_dir}/releasekey.pk8" ]]; then
        if [[ ! -f "${keys_dir}/keys.mk" ]]; then
            cat <<'EOF' > "${keys_dir}/keys.mk"
PRODUCT_DEFAULT_DEV_CERTIFICATE := vendor/lineage-priv/keys/releasekey
PRODUCT_MAINLINE_SEPOLICY_DEV_CERTIFICATES := $(dir $(PRODUCT_DEFAULT_DEV_CERTIFICATE))
PRODUCT_MAINLINE_BLUETOOTH_SEPOLICY_DEV_CERTIFICATES := $(dir $(PRODUCT_DEFAULT_DEV_CERTIFICATE))
EOF
        fi
        export ROM_KEYS_PATH="${keys_dir#${WORKSPACE_ROOT}/}"
        log "Signing OrangeFox with ROM release keys (${keys_dir}/releasekey)..."
    else
        warn "No releasekey.pk8 found in ${keys_dir} or ${external_certs}; OrangeFox will use default test keys."
    fi
}

setup_inline_kernel_env() {
    if [[ "${INLINE_KERNEL}" != "true" ]]; then
        log "Using stock prebuilt kernel fallback (TARGET_FORCE_PREBUILT_KERNEL=true)..."
        export TARGET_FORCE_PREBUILT_KERNEL="true"
        return 0
    fi
    log "Configuring Android NDK r30 LLVM environment for inline kernel compilation..."
    export PATH="${NDK_BIN}:${PATH}"
    export TARGET_KERNEL_CLANG_PATH="${NDK_BIN%/bin}"
    unset TARGET_FORCE_PREBUILT_KERNEL
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

    local cur_nofile
    cur_nofile="$(ulimit -Sn 2>/dev/null || echo 1024)"
    if [[ "${cur_nofile}" =~ ^[0-9]+$ ]] && (( cur_nofile < 65536 )); then
        ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
    fi

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

sign_orangefox_zip() {
    local zip_path="$1"
    local keys_dir="${WORKSPACE_ROOT}/vendor/lineage-priv/keys"
    local cert="${keys_dir}/releasekey.x509.pem"
    local key="${keys_dir}/releasekey.pk8"

    [[ -f "${zip_path}" ]] || return 0
    if [[ ! -f "${cert}" || ! -f "${key}" ]]; then
        warn "Release keys not found at ${keys_dir}; leaving ${zip_path} with default signature."
        return 0
    fi

    local signapk_jar=""
    for candidate in \
        "${WORKSPACE_ROOT}/out/host/linux-x86/framework/signapk.jar" \
        "${WORKSPACE_ROOT}/prebuilts/sdk/tools/lib/signapk.jar"; do
        if [[ -f "${candidate}" ]]; then
            signapk_jar="${candidate}"
            break
        fi
    done

    if [[ -z "${signapk_jar}" ]]; then
        warn "signapk.jar not found; cannot re-sign $(basename "${zip_path}") with release keys."
        return 0
    fi

    local tmp_signed="${zip_path}.signed"
    local lib_dir="${WORKSPACE_ROOT}/prebuilts/sdk/tools/linux/lib64"
    local jdk8_java="${WORKSPACE_ROOT}/prebuilts/jdk/jdk8/linux-x86/bin/java"
    local -a java_cmd=("java" "--add-exports=java.base/sun.security.x509=ALL-UNNAMED")
    if [[ -x "${jdk8_java}" ]]; then
        java_cmd=("${jdk8_java}")
    fi

    log "Signing $(basename "${zip_path}") with ROM releasekey (signapk)..."
    "${java_cmd[@]}" -Djava.library.path="${lib_dir}" -jar "${signapk_jar}" -w "${cert}" "${key}" "${zip_path}" "${tmp_signed}" || \
        die "Failed to sign ${zip_path} with releasekey."
    mv -f "${tmp_signed}" "${zip_path}"
    if [[ -f "${zip_path}.md5" ]]; then
        (cd "$(dirname "${zip_path}")" && md5sum "$(basename "${zip_path}")" > "$(basename "${zip_path}.md5")")
    fi
    log "[+] Signed flashable OrangeFox zip: ${zip_path}"
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

    local ofox_zip
    ofox_zip=$(find "${OUT}" -maxdepth 2 -type f -name "OrangeFox-*.zip" | head -n 1 || true)
    if [[ -n "${ofox_zip}" && -f "${ofox_zip}" ]]; then
        sign_orangefox_zip "${ofox_zip}"
    fi

    local pub_dir="/var/www/html/kelexine"
    if [[ ( -d "${pub_dir}" && -w "${pub_dir}" ) || ( ! -d "${pub_dir}" && -w "/var/www/html" ) ]]; then
        mkdir -p "${pub_dir}" 2>/dev/null || true
        local dated_img="${pub_dir}/OrangeFox-12.1-${LOG_TIMESTAMP}-${DEVICE}.img"
        if cp -v "${recovery_img}" "${dated_img}" 2>/dev/null; then
            ln -sfn "$(basename "${dated_img}")" "${pub_dir}/OrangeFox-${DEVICE}-latest.img" 2>/dev/null || true
            log "[+] Published OrangeFox recovery image: https://ferrari.serverhive.in/kelexine/$(basename "${dated_img}")"
        fi

        if [[ -n "${ofox_zip}" && -f "${ofox_zip}" ]]; then
            local dated_zip="${pub_dir}/$(basename "${ofox_zip%.zip}")-${LOG_TIMESTAMP}.zip"
            if cp -v "${ofox_zip}" "${dated_zip}" 2>/dev/null; then
                ln -sfn "$(basename "${dated_zip}")" "${pub_dir}/OrangeFox-${DEVICE}-latest.zip" 2>/dev/null || true
                log "[+] Published OrangeFox recovery zip: https://ferrari.serverhive.in/kelexine/$(basename "${dated_zip}")"
            fi
        fi
    fi

    if [[ "${AUTO_RELEASE}" == "true" ]]; then
        local push_script
        push_script="$(resolve_push_script)"
        [[ -n "${push_script}" ]] || die "Automatic release requested (-r/--release), but push-release.sh not found."
        local tag="${RELEASE_TAG_OVERRIDE:-ofrp-12.1-$(date +%Y%m%d)}"
        local -a release_args=("--tag" "${tag}" "--title" "OrangeFox R12.1 Recovery for Cubot P50 (${DEVICE}) - ${tag}" "--no-ota-push")
        [[ "${RELEASE_PRERELEASE}" == "true" ]] && release_args+=("--prerelease")
        log "Triggering automatic release push via ${push_script}..."
        "${push_script}" "${release_args[@]}" "${OUT}" || die "Release upload failed."
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
    log "  Auto Release:  ${AUTO_RELEASE}"
    [[ -n "${JOB_COUNT}" ]] && log "  Job Count:     ${JOB_COUNT}"
    log "  Log File:      ${LOG_FILE}"
    log "=================================================="

    verify_prerequisites
    setup_signing_keys
    setup_inline_kernel_env
    init_ofrp_environment
    build_recovery_image

    local end_time
    end_time="$(date +%s)"
    log "[+] Total build time: $(format_duration $((end_time - start_time)))"
    log "[+] Build log saved to: ${LOG_FILE}"
}

main "$@"
