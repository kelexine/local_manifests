#!/usr/bin/env bash
# Script: build-axion.sh
# Author: kelexine <https://github.com/kelexine>
# Date: 2026-10-13
# Purpose: Automated AxionOS ROM build script for Cubot P50 (marlon/axion branch)
#          with inline kernel and in-tree MTK connectivity/MET modules compilation.
# Usage: ./build-axion.sh [variant] [gapps] [build-type] [options]
#        e.g.: ./build-axion.sh userdebug core -b -j192

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
TARGET_GAPPS_VARIANT="gms"
BUILD_TYPE="-b"
JOB_COUNT=""
ENABLE_PERF=true
ENABLE_SWAP=false
ENABLE_RBE=false
CLEAR_RBE=false
SKIP_GLOBS=false
KERNEL_ONLY=false
POST_ONLY=false
AUTO_RELEASE=false
ARCHIVE_BASELINE=true
BUILD_INCREMENTAL=true
INCREMENTAL_FROM=""
OTA_JSON_SOURCE="${OTA_JSON_URL:-}"
BASELINE_DIR="${HOME}/ota-baselines"
OTA_JSON_OUT=""
BASELINE_BASE_URL="${OTA_BASELINE_BASE_URL:-}"
BASELINE_URL="${OTA_BASELINE_URL:-}"
SF_DEST="${OTA_SF_DEST:-}"
SKIP_SF=false
SKIP_OTA_PUSH=false
SPLIT_BASELINE=false
RELEASE_TAG_OVERRIDE=""
RELEASE_PRERELEASE=false
CURRENT_TARGET_FILES_ZIP=""
PREV_TARGET_FILES_ZIP=""
INCREMENTAL_ZIP_PATH=""

readonly KERNEL_SRC="${WORKSPACE_ROOT}/kernel/cubot/${DEVICE}"

readonly NDK_DIR="${HOME}/Android/Ndk/android-ndk-r30"
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
  gms | core | pico | full | vanilla (default: gms)

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
  --kernel-only, bKernel, -k      Build only inline kernel, dtbs, and in-tree modules
  --post-only                     Skip ROM build; run post-build baseline, incremental OTA, and release steps
  --no-baseline                   Skip packaging target-files baseline zip after bacon build
  --incremental / --no-incremental Generate incremental OTA zip (default: enabled for -b)
  --incremental-from <zip|url>    Explicit previous target-files zip path or URL for incremental OTA
  --ota-json <url|file>           OTA JSON URL/path to resolve previous target-files baseline (env: OTA_JSON_URL)
  --baseline-dir <dir>            Directory to cache/archive target-files zips (default: ~/ota-baselines)
  --baseline-url <url>            Explicit target-files download URL passed to push-release.sh (env: OTA_BASELINE_URL)
  --baseline-base-url <url>       Base URL for uploaded target-files baseline (env: OTA_BASELINE_BASE_URL)
  --sf-dest <rsync-dest>          SourceForge FRS rsync target for baseline upload (env: OTA_SF_DEST)
  --no-sf                         Skip SourceForge target-files upload when releasing
  --no-ota-push                   Skip automatic commit & push to cubot-marlon-rom-releases when releasing
  --split-baseline                Split target-files zip into <=1.8GiB GitHub Release parts if not using external host
  --ota-json-out <file>           Output path for updated axion.json passed to push-release.sh
  --tag <tag>                     Explicit GitHub release tag passed to push-release.sh
  --prerelease                    Mark GitHub release as pre-release
  --release, -r                   Push completed build artifacts (GitHub + SourceForge + OTA JSON)

Examples:
  ./build.sh
  ./build.sh -r
  ./build.sh user core -b -j192 --release
  ./build.sh userdebug vanilla --no-incremental
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
            --post-only)
                POST_ONLY=true
                ;;
            --no-baseline)
                ARCHIVE_BASELINE=false
                ;;
            --incremental)
                BUILD_INCREMENTAL=true
                ;;
            --no-incremental)
                BUILD_INCREMENTAL=false
                ;;
            --incremental-from)
                [[ -n "${2:-}" ]] || die "Option $1 requires a path or URL."
                BUILD_INCREMENTAL=true
                INCREMENTAL_FROM="$2"
                shift
                ;;
            --ota-json)
                [[ -n "${2:-}" ]] || die "Option $1 requires a URL or file path."
                OTA_JSON_SOURCE="$2"
                shift
                ;;
            --baseline-dir)
                [[ -n "${2:-}" ]] || die "Option $1 requires a directory path."
                BASELINE_DIR="$2"
                shift
                ;;
            --baseline-url)
                [[ -n "${2:-}" ]] || die "Option $1 requires a URL."
                BASELINE_URL="$2"
                shift
                ;;
            --baseline-base-url)
                [[ -n "${2:-}" ]] || die "Option $1 requires a base URL."
                BASELINE_BASE_URL="$2"
                shift
                ;;
            --sf-dest)
                [[ -n "${2:-}" ]] || die "Option $1 requires an rsync destination."
                SF_DEST="$2"
                shift
                ;;
            --no-sf)
                SKIP_SF=true
                ;;
            --no-ota-push)
                SKIP_OTA_PUSH=true
                ;;
            --split-baseline)
                SPLIT_BASELINE=true
                ;;
            --ota-json-out)
                [[ -n "${2:-}" ]] || die "Option $1 requires a file path."
                OTA_JSON_OUT="$2"
                shift
                ;;
            --tag)
                [[ -n "${2:-}" ]] || die "Option $1 requires a release tag."
                RELEASE_TAG_OVERRIDE="$2"
                shift
                ;;
            --prerelease)
                RELEASE_PRERELEASE=true
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

resolve_push_script() {
    if [[ -x "${WORKSPACE_ROOT}/push-release.sh" ]]; then
        echo "${WORKSPACE_ROOT}/push-release.sh"
    elif [[ -x "${SCRIPT_DIR}/push-release.sh" ]]; then
        echo "${SCRIPT_DIR}/push-release.sh"
    elif [[ -x "${WORKSPACE_ROOT}/.repo/local_manifests/push-release.sh" ]]; then
        echo "${WORKSPACE_ROOT}/.repo/local_manifests/push-release.sh"
    elif command -v push-release.sh >/dev/null 2>&1; then
        command -v push-release.sh
    fi
}

warn_release_prerequisites() {
    [[ "${AUTO_RELEASE}" == "true" && "${KERNEL_ONLY}" != "true" ]] || return 0
    if [[ -z "$(resolve_push_script)" ]]; then
        warn "Release requested (-r), but push-release.sh not found; build will proceed and fail at release step."
    fi
    if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
        warn "Release requested (-r), but GitHub CLI is not authenticated; build will proceed and fail at upload."
    fi
    if [[ "${SKIP_SF}" != "true" && "${SPLIT_BASELINE}" != "true" ]]; then
        local -a sftp_opts=(-b /dev/null -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=no)
        [[ -f "${HOME}/.ssh/sf_key" ]] && sftp_opts+=(-i "${HOME}/.ssh/sf_key")
        if ! command -v sftp >/dev/null 2>&1 || ! sftp "${sftp_opts[@]}" "kelexine@frs.sourceforge.net:/home/frs/project/cubot-marlon-rom-releases/" >/dev/null 2>&1; then
            warn "Release requested (-r), but SourceForge FRS SSH is not active (did you pass ssh -A?); build will proceed and fail at upload."
        fi
    fi
}

verify_prerequisites() {
    log "Verifying build prerequisites..."
    [[ -d "${NDK_BIN}" ]] || die "NDK r30 toolchain not found at ${NDK_BIN}. Please run setup.sh first."
    [[ -f "${WORKSPACE_ROOT}/build/envsetup.sh" ]] || die "Workspace root is not an Android build tree (${WORKSPACE_ROOT})."
    [[ -d "${KERNEL_SRC}" ]] || die "Kernel source missing at ${KERNEL_SRC}."
}

setup_kernel_toolchain_env() {
    log "Configuring Android NDK r30 LLVM environment for kernel compilation..."
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

read_zip_prop() {
    local zip_path="$1"
    local key="$2"
    python3 - "$zip_path" "$key" <<'PY'
import sys, zipfile
zip_path, key = sys.argv[1], sys.argv[2]
prefix = key + "="
with zipfile.ZipFile(zip_path) as zf:
    for candidate in ("SYSTEM/build.prop", "PRODUCT/etc/build.prop"):
        if candidate in zf.namelist():
            for line in zf.read(candidate).decode("utf-8", "replace").splitlines():
                if line.startswith(prefix):
                    print(line[len(prefix):].strip())
                    sys.exit(0)
PY
}

package_and_archive_baseline() {
    local out_target="$1"
    [[ "${BUILD_TYPE}" == "-b" ]] || return 0
    if [[ "${ARCHIVE_BASELINE}" != "true" && "${BUILD_INCREMENTAL}" != "true" ]]; then
        return 0
    fi

    local primary_zip
    primary_zip="$(find "${out_target}" -maxdepth 1 -type f -name 'axion-*.zip' ! -name '*-ota.zip' ! -name '*-INCREMENTAL-*.zip' -printf '%f\n' | sort -r | head -n 1 || true)"
    local build_date=""
    if [[ "${primary_zip}" =~ -([0-9]{8})- ]]; then
        build_date="${BASH_REMATCH[1]}"
    else
        build_date="$(date +%Y%m%d)"
    fi

    local tf_interm="${out_target}/obj/PACKAGING/target_files_intermediates/lineage_${DEVICE}-target_files"
    local soong_zip="${WORKSPACE_ROOT}/out/host/linux-x86/bin/soong_zip"
    mkdir -p "${BASELINE_DIR}"

    local curr_utc=""
    if [[ -f "${tf_interm}/SYSTEM/build.prop" ]]; then
        curr_utc="$(grep -m1 '^ro\.build\.date\.utc=' "${tf_interm}/SYSTEM/build.prop" | cut -d'=' -f2 | tr -d '\r\n' || true)"
    fi

    local archive_zip="${BASELINE_DIR}/${DEVICE}-target_files-${build_date}.zip"
    if [[ -f "${archive_zip}" && -n "${curr_utc}" ]]; then
        local existing_utc
        existing_utc="$(read_zip_prop "${archive_zip}" "ro.build.date.utc" || true)"
        if [[ -n "${existing_utc}" && "${existing_utc}" != "${curr_utc}" ]]; then
            archive_zip="${BASELINE_DIR}/${DEVICE}-target_files-${build_date}-${curr_utc}.zip"
        fi
    fi

    if [[ -x "${soong_zip}" && -d "${tf_interm}" && -f "${tf_interm}.zip.list" ]]; then
        local tf_interm_rel="${tf_interm#"${WORKSPACE_ROOT}/"}"
        log "Packaging target-files baseline via soong_zip -> ${archive_zip}"
        (
            cd "${WORKSPACE_ROOT}"
            "${soong_zip}" -d -o "${archive_zip}" -C "${tf_interm_rel}" -r "${tf_interm}.zip.list" -sha256
        ) || die "soong_zip target-files packaging failed."
    else
        log "Building target-files-package via mka..."
        mka target-files-package || die "target-files-package build failed."
        cp -f "${tf_interm}.zip" "${archive_zip}"
    fi

    sha256sum "${archive_zip}" > "${archive_zip}.sha256"
    CURRENT_TARGET_FILES_ZIP="${archive_zip}"
    log "[+] Archived target-files baseline: ${CURRENT_TARGET_FILES_ZIP}"
}

resolve_previous_baseline() {
    PREV_TARGET_FILES_ZIP=""

    if [[ -n "${INCREMENTAL_FROM}" ]]; then
        if [[ -f "${INCREMENTAL_FROM}" ]]; then
            PREV_TARGET_FILES_ZIP="$(cd "$(dirname "${INCREMENTAL_FROM}")" && pwd)/$(basename "${INCREMENTAL_FROM}")"
            return 0
        elif [[ "${INCREMENTAL_FROM}" =~ ^https?:// ]]; then
            mkdir -p "${BASELINE_DIR}"
            local dl_name
            dl_name="$(basename "${INCREMENTAL_FROM%%\?*}")"
            [[ "${dl_name}" == "download" || -z "${dl_name}" ]] && dl_name="${DEVICE}-prev-target_files.zip"
            local dl_path="${BASELINE_DIR}/${dl_name}"
            log "Downloading explicit baseline from ${INCREMENTAL_FROM}..."
            curl -fL --retry 3 -o "${dl_path}" "${INCREMENTAL_FROM}" || die "Failed to download baseline: ${INCREMENTAL_FROM}"
            PREV_TARGET_FILES_ZIP="${dl_path}"
            return 0
        else
            die "Explicit --incremental-from target not found: ${INCREMENTAL_FROM}"
        fi
    fi

    local ota_variant="GMS"
    [[ "${TARGET_GAPPS_VARIANT}" == "vanilla" ]] && ota_variant="VANILLA"

    local json_src="${OTA_JSON_SOURCE}"
    if [[ -z "${json_src}" ]]; then
        json_src="https://raw.githubusercontent.com/kelexine/cubot-marlon-rom-releases/main/OTA/${ota_variant}/axion.json"
    fi

    local curr_utc=""
    curr_utc="$(read_zip_prop "${CURRENT_TARGET_FILES_ZIP}" "ro.build.date.utc" || true)"

    if [[ -n "${json_src}" ]]; then
        log "Resolving previous baseline via OTA JSON: ${json_src}"
        if PREV_TARGET_FILES_ZIP="$(python3 - "${json_src}" "${BASELINE_DIR}" "${curr_utc}" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, urllib.request

json_src, baseline_dir_str, curr_utc = sys.argv[1], sys.argv[2], sys.argv[3]
baseline_dir = pathlib.Path(baseline_dir_str)
baseline_dir.mkdir(parents=True, exist_ok=True)

def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def sf_frs_path(url: str) -> str | None:
    import re
    m = re.match(r"^https?://sourceforge\.net/projects/([^/]+)/files/(.+?)(?:/download)?/?$", url)
    if m:
        return f"/home/frs/project/{m.group(1)}/{m.group(2)}"
    return None

def download_file(url: str, dst: pathlib.Path) -> None:
    frs_path = sf_frs_path(url)
    if frs_path:
        sf_user = os.environ.get("OTA_SF_USER", "kelexine")
        sf_host = os.environ.get("OTA_SF_HOST", "frs.sourceforge.net")
        sftp_cmd = [
            "sftp",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "IdentitiesOnly=no",
        ]
        sf_key = pathlib.Path.home() / ".ssh" / "sf_key"
        if sf_key.is_file():
            sftp_cmd.extend(["-i", str(sf_key)])
        sftp_cmd.extend([f"{sf_user}@{sf_host}:{frs_path}", str(dst)])
        print(f"Downloading baseline via SourceForge SFTP: {sf_user}@{sf_host}:{frs_path}", file=sys.stderr, flush=True)
        res = subprocess.run(sftp_cmd)
        if res.returncode == 0 and dst.is_file() and dst.stat().st_size > 0:
            return
        print("SourceForge SFTP failed or unavailable; falling back to curl...", file=sys.stderr, flush=True)
        dst.unlink(missing_ok=True)
    subprocess.run(["curl", "-fL", "--retry", "3", "-o", str(dst), url], check=True)

if json_src.startswith(("http://", "https://")):
    req = urllib.request.Request(json_src, headers={"User-Agent": "axion-build-ota/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8"))
else:
    data = json.loads(pathlib.Path(json_src).read_text(encoding="utf-8"))

entries = data.get("response") or []
if not entries:
    sys.exit(0)
latest = entries[0]
if curr_utc and str(latest.get("datetime", "")) == curr_utc:
    print("SAME_BUILD")
    sys.exit(0)

tf = latest.get("target_files") or {}
filename = tf.get("filename") or ""
expected_sha = (tf.get("sha256") or "").lower()
single_url = tf.get("url") or ""
parts = tf.get("parts") or []
if not filename:
    sys.exit(0)

dst = baseline_dir / filename
if dst.is_file():
    if not expected_sha or sha256_file(dst) == expected_sha:
        print(str(dst))
        sys.exit(0)
    dst.unlink()

if single_url:
    download_file(single_url, dst)
elif parts:
    part_paths = []
    for idx, part in enumerate(parts):
        purl = part.get("url") or ""
        if not purl:
            sys.exit(2)
        pname = part.get("filename") or f"{filename}.part-{idx:02d}"
        ppath = baseline_dir / pname
        psha = (part.get("sha256") or "").lower()
        if not ppath.is_file() or (psha and sha256_file(ppath) != psha):
            download_file(purl, ppath)
            if psha and sha256_file(ppath) != psha:
                raise RuntimeError(f"Checksum mismatch on part {pname}")
        part_paths.append(ppath)
    with dst.open("wb") as out_f:
        for ppath in part_paths:
            with ppath.open("rb") as in_f:
                while buf := in_f.read(4 * 1024 * 1024):
                    out_f.write(buf)
else:
    sys.exit(0)

if expected_sha and sha256_file(dst) != expected_sha:
    dst.unlink(missing_ok=True)
    raise RuntimeError(f"Checksum mismatch on {filename}")

print(str(dst))
PY
)"; then
            if [[ "${PREV_TARGET_FILES_ZIP}" == "SAME_BUILD" ]]; then
                warn "OTA JSON points to the exact same build timestamp (${curr_utc}); skipping incremental OTA."
                PREV_TARGET_FILES_ZIP=""
                return 0
            fi
            [[ -n "${PREV_TARGET_FILES_ZIP}" ]] && return 0
        elif [[ -n "${OTA_JSON_SOURCE}" ]]; then
            die "Failed resolving baseline from explicit OTA JSON (${json_src})."
        else
            warn "Could not resolve default remote OTA JSON (${json_src}); falling back to local ${BASELINE_DIR} cache."
            PREV_TARGET_FILES_ZIP=""
        fi
    fi

    # Offline cache fallback: pick newest other target-files zip in BASELINE_DIR
    local candidate
    while IFS= read -r candidate; do
        [[ -z "${candidate}" ]] && continue
        if [[ "${candidate}" != "${CURRENT_TARGET_FILES_ZIP}" ]]; then
            PREV_TARGET_FILES_ZIP="${candidate}"
            return 0
        fi
    done < <(ls -t "${BASELINE_DIR}/${DEVICE}-target_files-"*.zip 2>/dev/null || true)
}

generate_incremental_ota() {
    local out_target="$1"
    [[ "${BUILD_INCREMENTAL}" == "true" ]] || return 0
    [[ -n "${CURRENT_TARGET_FILES_ZIP}" && -f "${CURRENT_TARGET_FILES_ZIP}" ]] || {
        warn "Current target-files zip missing; skipping incremental OTA generation."
        return 0
    }

    resolve_previous_baseline
    if [[ -z "${PREV_TARGET_FILES_ZIP}" || ! -f "${PREV_TARGET_FILES_ZIP}" ]]; then
        warn "No previous target-files baseline found; skipping incremental OTA (this build is still archived as next baseline)."
        return 0
    fi

    local prev_utc curr_utc
    prev_utc="$(read_zip_prop "${PREV_TARGET_FILES_ZIP}" "ro.build.date.utc" || true)"
    curr_utc="$(read_zip_prop "${CURRENT_TARGET_FILES_ZIP}" "ro.build.date.utc" || true)"
    if [[ -n "${prev_utc}" && -n "${curr_utc}" && "${prev_utc}" -ge "${curr_utc}" ]]; then
        warn "Source baseline UTC (${prev_utc}) >= target UTC (${curr_utc}); skipping incremental OTA."
        return 0
    fi

    local prev_date curr_date curr_stamp
    prev_date="$(date -u -d "@${prev_utc:-0}" +%Y%m%d 2>/dev/null || basename "${PREV_TARGET_FILES_ZIP}" | grep -oE '[0-9]{8}' | head -n1 || echo "prev")"
    curr_date="$(date -u -d "@${curr_utc:-0}" +%Y%m%d 2>/dev/null || date +%Y%m%d)"
    curr_stamp="${curr_utc:-$(date -u +%s)}"

    local primary_zip
    primary_zip="$(find "${out_target}" -maxdepth 1 -type f -name 'axion-*.zip' ! -name '*-ota.zip' ! -name '*-INCREMENTAL-*.zip' -printf '%f\n' | sort -r | head -n 1 || true)"
    local incr_name
    if [[ "${primary_zip}" =~ ^(axion-[0-9.]+-[A-Za-z0-9_]+)-[0-9]{8}-(.*)\.zip$ ]]; then
        incr_name="${BASH_REMATCH[1]}-${prev_date}-to-${curr_date}-${curr_stamp}-INCREMENTAL-${BASH_REMATCH[2]}.zip"
    else
        incr_name="axion-${DEVICE}-${prev_date}-to-${curr_date}-${curr_stamp}-INCREMENTAL.zip"
    fi

    local incr_path="${out_target}/${incr_name}"
    local ota_tool="${WORKSPACE_ROOT}/out/host/linux-x86/bin/ota_from_target_files"
    local key_pair="${WORKSPACE_ROOT}/vendor/lineage-priv/keys/releasekey"
    [[ -x "${ota_tool}" ]] || die "ota_from_target_files not found at ${ota_tool}"
    [[ -f "${key_pair}.pk8" ]] || die "Release signing key not found at ${key_pair}.pk8"

    log "Generating incremental OTA (${prev_date} -> ${curr_date})..."
    log "  Source baseline: ${PREV_TARGET_FILES_ZIP}"
    log "  Target baseline: ${CURRENT_TARGET_FILES_ZIP}"
    PATH="${WORKSPACE_ROOT}/out/host/linux-x86/bin:${PATH}" "${ota_tool}" \
        --verbose \
        --path "${WORKSPACE_ROOT}/out/host/linux-x86" \
        -k "${key_pair}" \
        -i "${PREV_TARGET_FILES_ZIP}" \
        "${CURRENT_TARGET_FILES_ZIP}" \
        "${incr_path}" || die "ota_from_target_files incremental build failed."

    sha256sum "${incr_path}" > "${incr_path}.sha256"
    INCREMENTAL_ZIP_PATH="${incr_path}"
    log "[+] Incremental OTA built: ${INCREMENTAL_ZIP_PATH} ($(du -h "${incr_path}" | awk '{print $1}'))"
}

build_rom_package() {
    local out_target="${OUT:-${ANDROID_PRODUCT_OUT:-${WORKSPACE_ROOT}/out/target/product/${DEVICE}}}"

    if [[ "${POST_ONLY}" == "true" ]]; then
        log "Skipping ROM compilation (--post-only); continuing post-build packaging..."
    else
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

        out_target="${OUT:-${ANDROID_PRODUCT_OUT:-${WORKSPACE_ROOT}/out/target/product/${DEVICE}}}"
        log "[+] Build completed successfully!"
    fi
    log "[+] Output images located at: ${out_target}"

    package_and_archive_baseline "${out_target}"
    generate_incremental_ota "${out_target}"

    local pub_dir="/var/www/html/kelexine"
    if [[ -d "/var/www/html" && -w "/var/www/html" ]] || [[ -w "${pub_dir}" ]]; then
        mkdir -p "${pub_dir}" 2>/dev/null || true
        if compgen -G "${out_target}/axion*.zip" > /dev/null; then
            cp -v "${out_target}"/axion*.zip "${pub_dir}/" 2>/dev/null || true
            local latest_zip
            latest_zip="$(find "${out_target}" -maxdepth 1 -name 'axion*.zip' ! -name '*-INCREMENTAL-*.zip' | head -n 1 || true)"
            [[ -n "${latest_zip}" ]] && ln -sfn "$(basename "${latest_zip}")" "${pub_dir}/axion-marlon-latest.zip" 2>/dev/null || true
            log "[+] Published ROM zip: https://ferrari.serverhive.in/kelexine/"
        fi
    fi

    if [[ "${AUTO_RELEASE}" == "true" ]]; then
        local push_script
        push_script="$(resolve_push_script)"

        if [[ -n "${push_script}" ]]; then
            local -a release_args=()
            [[ -n "${INCREMENTAL_ZIP_PATH}" ]] && release_args+=("--incremental" "${INCREMENTAL_ZIP_PATH}")
            [[ -n "${PREV_TARGET_FILES_ZIP}" ]] && release_args+=("--base-target-files" "${PREV_TARGET_FILES_ZIP}")
            [[ -n "${CURRENT_TARGET_FILES_ZIP}" ]] && release_args+=("--target-files" "${CURRENT_TARGET_FILES_ZIP}")
            [[ -n "${BASELINE_URL}" ]] && release_args+=("--baseline-url" "${BASELINE_URL}")
            [[ -n "${BASELINE_BASE_URL}" ]] && release_args+=("--baseline-base-url" "${BASELINE_BASE_URL}")
            [[ -n "${SF_DEST}" ]] && release_args+=("--sf-dest" "${SF_DEST}")
            [[ "${SKIP_SF}" == "true" ]] && release_args+=("--no-sf")
            [[ "${SKIP_OTA_PUSH}" == "true" ]] && release_args+=("--no-ota-push")
            [[ "${SPLIT_BASELINE}" == "true" ]] && release_args+=("--split-baseline")
            [[ -n "${OTA_JSON_OUT}" ]] && release_args+=("--ota-json-out" "${OTA_JSON_OUT}")
            [[ -n "${RELEASE_TAG_OVERRIDE}" ]] && release_args+=("--tag" "${RELEASE_TAG_OVERRIDE}")
            [[ "${RELEASE_PRERELEASE}" == "true" ]] && release_args+=("--prerelease")

            log "Triggering automatic release push via ${push_script}..."
            "${push_script}" "${release_args[@]}" "${out_target}" || die "Release upload failed."
        else
            die "Automatic release requested (-r/--release), but push-release.sh was not found or is not executable."
        fi
    else
        log "[*] To publish this build (GitHub Release + SourceForge + OTA JSON), run:"
        log "    ./push-release.sh"
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
    log "  Incremental:  ${BUILD_INCREMENTAL}"
    log "  Auto Release: ${AUTO_RELEASE}"
    [[ -n "${JOB_COUNT}" ]] && log "  Job Count:    ${JOB_COUNT}"
    log "  Log File:     ${LOG_FILE}"
    log "=================================================="

    verify_prerequisites
    warn_release_prerequisites
    if [[ "${POST_ONLY}" != "true" ]]; then
        setup_kernel_toolchain_env
        init_android_environment
    fi

    if [[ "${KERNEL_ONLY}" == "true" ]]; then
        if declare -F bKernel >/dev/null; then
            log "Building kernel, boot, and module images via Axion bKernel..."
            bKernel || die "bKernel failed."
        else
            build_inline_kernel
        fi
        log "[+] Kernel build completed successfully."
    else
        build_rom_package
    fi

    local end_time
    end_time="$(date +%s)"
    log "[+] Total build time: $(format_duration $((end_time - start_time)))"
    log "[+] Build log saved to: ${LOG_FILE}"
}

main "$@"
