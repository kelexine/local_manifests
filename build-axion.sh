#!/usr/bin/env bash
# Script: build-axion.sh
# Author: kelexine <https://github.com/kelexine>
# Date: 2026-10-13
# Purpose: Automated AxionOS ROM build script for Cubot P50 (marlon/axion branch)
#          with inline kernel compilation and out-of-tree MTK connectivity modules.
# Usage: ./build-axion.sh [variant] [gapps] [build-type] [options]
#        e.g.: ./build-axion.sh userdebug core -b -j192

set -eo pipefail

# --- Configuration & Paths ---
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WORKSPACE_ROOT="${SCRIPT_DIR}"
readonly DEVICE="marlon"

TARGET_VARIANT="userdebug"
TARGET_GAPPS_VARIANT="core"
BUILD_TYPE="-b"
JOB_COUNT=""
ENABLE_PERF=true
ENABLE_SWAP=false
ENABLE_RBE=false
CLEAR_RBE=false
SKIP_GLOBS=false
KERNEL_ONLY=false

readonly KERNEL_SRC="${WORKSPACE_ROOT}/kernel/cubot/${DEVICE}"
readonly MODULES_SRC="${WORKSPACE_ROOT}/kernel/cubot/${DEVICE}-modules"
readonly VENDOR_TREE_DIR="${WORKSPACE_ROOT}/vendor/cubot/${DEVICE}"

readonly NDK_DIR="${HOME}/Android/Ndk/android-ndk-r29"
readonly NDK_BIN="${NDK_DIR}/toolchains/llvm/prebuilt/linux-x86_64/bin"

readonly LOG_DIR="${WORKSPACE_ROOT}/logs"
readonly SCRIPT_BASE="$(basename "${0}" .sh)"
readonly LOG_TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_BASE}_${LOG_TIMESTAMP}.log"
readonly LATEST_LOG="${LOG_DIR}/${SCRIPT_BASE}_latest.log"
readonly ROOT_LOG="${WORKSPACE_ROOT}/build.log"

log()   { printf '\033[1;36m[build-axion]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[build-axion]\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m[build-axion]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

show_help() {
    cat <<'EOF'
AxionOS Build Script for Cubot P50 (marlon)

Usage: ./build-axion.sh [variant] [gapps] [build-type] [options]

Build Variants:
  user | userdebug | eng          (default: userdebug)

GApps Variants:
  core | gms | pico | full | vanilla (default: core)

Build Types:
  -b                              Bacon (full flashable ZIP, default)
  -fb                             Fastboot (fastboot flashable images)
  -br                             Brunch

Optimizations & Options:
  -j<num>                         Job count (e.g. -j16, -j192)
  --perf / --no-perf              Enable/disable setupPerf build optimizations (default: enabled)
  --swap                          Enable 64GB swap via setupSwap
  --rbe                           Enable local RBE cache via setupRBE
  --clear-rbe                     Discard local RBE action cache via clearRBECache
  --skip-globs                    Skip ninja globs via skipGlobs 1
  --kernel-only, bKernel, -k      Build only inline kernel + out-of-tree modules

Examples:
  ./build.sh userdebug
  ./build.sh user core -b -j192
  ./build.sh userdebug vanilla --skip-globs
  ./build.sh --kernel-only
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            user|userdebug|eng)
                TARGET_VARIANT="$1"
                ;;
            gms|pico|core|full|vanilla)
                TARGET_GAPPS_VARIANT="$1"
                ;;
            -b|-fb|-br)
                BUILD_TYPE="$1"
                ;;
            -j*)
                if [[ "$1" == "-j" ]]; then
                    shift
                    JOB_COUNT="${1:-}"
                else
                    JOB_COUNT="${1#-j}"
                fi
                ;;
            --perf)
                ENABLE_PERF=true
                ;;
            --no-perf)
                ENABLE_PERF=false
                ;;
            --swap)
                ENABLE_SWAP=true
                ;;
            --rbe)
                ENABLE_RBE=true
                ;;
            --clear-rbe)
                CLEAR_RBE=true
                ;;
            --skip-globs)
                SKIP_GLOBS=true
                ;;
            --kernel-only|bKernel|-k)
                KERNEL_ONLY=true
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
    [[ -d "${MODULES_SRC}" ]] || die "Kernel modules source missing at ${MODULES_SRC}."
}

ensure_vendor_symlinks() {
    log "Ensuring kernel tree vendor symlinks for out-of-tree and platform builds..."
    mkdir -p "${WORKSPACE_ROOT}/kernel/cubot"
    if [[ -d "${MODULES_SRC}/source/vendor" ]]; then
        ln -sfn "../${DEVICE}-modules/source/vendor" "${KERNEL_SRC}/vendor"
        ln -sfn "${DEVICE}-modules/source/vendor" "${WORKSPACE_ROOT}/kernel/cubot/vendor"
    elif [[ -d "${MODULES_SRC}/vendor" ]]; then
        ln -sfn "../${DEVICE}-modules/vendor" "${KERNEL_SRC}/vendor"
        ln -sfn "${DEVICE}-modules/vendor" "${WORKSPACE_ROOT}/kernel/cubot/vendor"
    fi
    log "  [+] Kernel vendor symlink verified: ${KERNEL_SRC}/vendor -> $(readlink -f "${KERNEL_SRC}/vendor" 2>/dev/null || true)"
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
    log "Initializing AOSP / AxionOS build environment..."
    cd "${WORKSPACE_ROOT}"
    export ANDROID_BUILD_TOP="${WORKSPACE_ROOT}"
    export ANDROID_KEY_PATH="${WORKSPACE_ROOT}/vendor/lineage-priv/keys"

    # Purge any conflicting manifests in .repo/local_manifests to ensure build-manifest.xml succeeds
    if [[ -d "${WORKSPACE_ROOT}/.repo/local_manifests" ]]; then
        find "${WORKSPACE_ROOT}/.repo/local_manifests" -maxdepth 1 -name '*.xml' ! -name 'axion.xml' -exec rm -f {} +
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

    # Axion build optimizations
    if [[ "${ENABLE_PERF}" == "true" ]] && declare -F setupPerf >/dev/null; then
        log "Running setupPerf build optimization..."
        setupPerf || true
    fi
    if [[ "${ENABLE_SWAP}" == "true" ]] && declare -F setupSwap >/dev/null; then
        log "Enabling 64GB swap via setupSwap..."
        setupSwap || true
    fi
    if [[ "${ENABLE_RBE}" == "true" ]] && declare -F setupRBE >/dev/null; then
        log "Enabling local RBE cache via setupRBE..."
        setupRBE || true
    fi
    if [[ "${CLEAR_RBE}" == "true" ]] && declare -F clearRBECache >/dev/null; then
        log "Discarding local RBE action cache via clearRBECache..."
        clearRBECache || true
    fi
    if [[ "${SKIP_GLOBS}" == "true" ]] && declare -F skipGlobs >/dev/null; then
        log "Configuring skipGlobs 1..."
        skipGlobs 1 || true
    fi

    # GMS Configuration
    if [[ "${TARGET_GAPPS_VARIANT}" == "vanilla" ]]; then
        export WITH_GMS=false
    else
        export WITH_GMS=true
    fi
    export TARGET_GAPPS_VARIANT="${TARGET_GAPPS_VARIANT}"
    export TARGET_INCLUDE_GOOGLE_TELECOMM=false

    if declare -F axion >/dev/null; then
        log "Initializing target via axion helper: axion ${DEVICE} ${TARGET_VARIANT} ${TARGET_GAPPS_VARIANT}..."
        axion "${DEVICE}" "${TARGET_VARIANT}" "${TARGET_GAPPS_VARIANT}" || die "Failed to target via axion."
    else
        local lunch_combo="lineage_${DEVICE}-${target_release}-${TARGET_VARIANT}"
        log "Selecting lunch target: ${lunch_combo} (GMS: ${TARGET_GAPPS_VARIANT}, Telecomm: ${TARGET_INCLUDE_GOOGLE_TELECOMM})..."
        lunch "${lunch_combo}" || die "Failed to lunch ${lunch_combo}."
    fi
}

build_inline_kernel() {
    log "Building inline kernel and dtbs via mka..."
    mka kernel dtboimage || die "Kernel compilation failed."
}

build_and_stage_oot_modules() {
    log "Compiling out-of-tree kernel modules against newly built KERNEL_OBJ..."
    local kernel_out="${OUT}/obj/KERNEL_OBJ"
    [[ -d "${kernel_out}" ]] || die "KERNEL_OBJ not found at ${kernel_out}."

    local modules_top="${MODULES_SRC}"
    [[ -d "${MODULES_SRC}/source/vendor" ]] && modules_top="${MODULES_SRC}/source"
    local vendor_dir="${modules_top}/vendor"
    local conn="${vendor_dir}/mediatek/kernel_modules/connectivity"

    local std_vars=(
        CONFIG_MTK_PLATFORM="mt6765"
        CONFIG_MTK_COMBO_CHIP='"CONSYS_6765"'
        KERNEL_OUT="${kernel_out}"
        TOP="${modules_top}"
        ARCH="arm64"
        LLVM=1
        LLVM_IAS=1
        CC="clang"
        LD="ld.lld"
        AR="llvm-ar"
        NM="llvm-nm"
        OBJCOPY="llvm-objcopy"
        OBJDUMP="llvm-objdump"
        STRIP="llvm-strip"
        CLANG_TRIPLE="aarch64-linux-gnu-"
        CROSS_COMPILE="aarch64-linux-gnu-"
    )

    local target_oot_modules="${OUT}/obj/KERNEL_MODULES_OOT"
    local target_vendor_modules="${OUT}/vendor/lib/modules"
    mkdir -p "${target_oot_modules}"
    mkdir -p "${target_vendor_modules}"

    compile_module() {
        local name="$1"; local src="$2"; shift 2
        log "  -> Compiling ${name}..."
        make -C "${KERNEL_SRC}" O="${kernel_out}" M="${src}" \
            -j"$(nproc)" \
            KCFLAGS="-Wno-error -Wno-error=strict-prototypes -Wno-strict-prototypes" \
            "${std_vars[@]}" "$@" modules

        local built_ko
        built_ko="$(find "${src}" -maxdepth 2 -name "${name}.ko" | head -n 1)"
        [[ -f "${built_ko}" ]] || die "Failed to find built module ${name}.ko"

        "${STRIP}" --strip-debug "${built_ko}" -o "${target_oot_modules}/${name}.ko"
        cp -f "${target_oot_modules}/${name}.ko" "${target_vendor_modules}/${name}.ko"
        log "     [+] Staged ${name}.ko"
    }

    local wmt_sym="${conn}/common/Module.symvers"

    # 1. wmt_drv (conninfra + wmt core)
    compile_module "wmt_drv" "${conn}/common"

    # 2. gps_drv
    compile_module "gps_drv" "${conn}/gps" \
        CONFIG_MTK_GPS_SUPPORT=y KBUILD_EXTRA_SYMBOLS="${wmt_sym}"

    # 3. bt_drv (legacy STP chrdev)
    compile_module "bt_drv" "${conn}/bt/mt66xx/legacy" \
        MODULE_NAME=bt_drv KBUILD_EXTRA_SYMBOLS="${wmt_sym}"

    # 4. wmt_chrdev_wifi
    compile_module "wmt_chrdev_wifi" "${conn}/wlan/adaptor" \
        MODULE_NAME=wmt_chrdev_wifi KBUILD_EXTRA_SYMBOLS="${wmt_sym}"

    # 5. wlan_drv_gen4m
    compile_module "wlan_drv_gen4m" "${conn}/wlan/core/gen4m" \
        MTK_COMBO_CHIP=CONNAC WLAN_CHIP_ID=6765 \
        CONFIG_MTK_COMBO_WIFI_HIF=axi MODULE_NAME=wlan_drv_gen4m \
        MTK_ANDROID_WMT=y WIFI_ENABLE_GCOV=n MTK_ANDROID_EMI=y MTK_WLAN_SERVICE=yes \
        KBUILD_EXTRA_SYMBOLS="${wmt_sym} ${conn}/wlan/adaptor/Module.symvers"

    # 6. met
    compile_module "met" "${vendor_dir}/mediatek/kernel_modules/met_drv_v2"

    cat << 'EOF' > "${target_vendor_modules}/modules.load"
wmt_drv.ko
bt_drv.ko
gps_drv.ko
wmt_chrdev_wifi.ko
wlan_drv_gen4m.ko
met.ko
trace_mmstat.ko
kheaders.ko
EOF

    log "[+] All out-of-tree modules successfully compiled and staged."
}

build_rom_package() {
    log "Starting AxionOS ROM packaging (${BUILD_TYPE})..."
    local -a job_args=()
    if [[ -n "${JOB_COUNT}" ]]; then
        job_args=("-j${JOB_COUNT}")
    fi

    if declare -F ax >/dev/null; then
        log "Running: ax ${BUILD_TYPE} ${job_args[*]} ${TARGET_VARIANT}"
        ax "${BUILD_TYPE}" "${job_args[@]}" "${TARGET_VARIANT}" || die "Axion build (${BUILD_TYPE}) failed."
    else
        log "ax command not found in environment; falling back to mka bacon..."
        mka bacon "${job_args[@]}" || die "AxionOS packaging failed."
    fi

    log "[+] Build completed successfully!"
    log "[+] Output images located at: ${OUT}"

    local pub_dir="/var/www/html/kelexine"
    if [[ -d "/var/www/html" ]]; then
        mkdir -p "${pub_dir}"
        if compgen -G "${OUT}/axion*.zip" > /dev/null; then
            cp -v "${OUT}"/axion*.zip "${pub_dir}/" || true
            local latest_zip
            latest_zip="$(find "${OUT}" -maxdepth 1 -name 'axion*.zip' | head -n 1)"
            [[ -n "${latest_zip}" ]] && ln -sfn "$(basename "${latest_zip}")" "${pub_dir}/axion-marlon-latest.zip" 2>/dev/null || true
            log "[+] Published ROM zip: https://ferrari.serverhive.in/kelexine/"
        fi
    fi
}

main() {
    parse_arguments "$@"
    setup_logging
    local start_time
    start_time="$(date +%s)"

    log "=================================================="
    log "  AxionOS Build Automation for Cubot P50 (marlon)"
    log "  Variant:      ${TARGET_VARIANT}"
    log "  GApps:        ${TARGET_GAPPS_VARIANT}"
    log "  Build Type:   ${BUILD_TYPE}"
    [[ -n "${JOB_COUNT}" ]] && log "  Job Count:    ${JOB_COUNT}"
    log "  Log File:     ${LOG_FILE}"
    log "=================================================="

    verify_prerequisites
    ensure_vendor_symlinks
    setup_kernel_toolchain_env
    init_android_environment

    if [[ "${KERNEL_ONLY}" == "true" ]]; then
        if declare -F bKernel >/dev/null; then
            log "Building kernel, boot, and module images via Axion bKernel..."
            bKernel || die "bKernel failed."
        else
            build_inline_kernel
            build_and_stage_oot_modules
        fi
        log "[+] Kernel build completed successfully."
    else
        build_inline_kernel
        build_and_stage_oot_modules
        build_rom_package
    fi

    local end_time
    end_time="$(date +%s)"
    log "[+] Total build time: $(format_duration $((end_time - start_time)))"
    log "[+] Build log saved to: ${LOG_FILE}"
}

main "$@"
