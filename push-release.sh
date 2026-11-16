#!/usr/bin/env bash
# Script: push-release.sh
# Author: kelexine <https://github.com/kelexine>
# Date: 2026-10-25
# Purpose: Smart, idempotent GitHub release uploader for Cubot P50 (marlon) builds.
#          Supports AxionOS, LineageOS, OFRP, and TWRP target outputs.
# Usage: ./push-release.sh [options] [product-out-directory]
#
# Idempotency:
#   - Detects if the target tag/release already exists on GitHub.
#   - If existing: updates metadata/notes and clobbers/updates assets seamlessly.
#   - If missing: creates tag and release cleanly.
#   - Recomputes or validates SHA256 checksums automatically.

set -euo pipefail

# --- Color formatting helpers ---
log()   { printf '\033[1;32m[push-release]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[push-release]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[push-release]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# --- Defaults ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${SCRIPT_DIR}"
DEFAULT_REPO="kelexine/cubot-marlon-rom-releases"
TARGET_REPO="${DEFAULT_REPO}"
PRODUCT_DIR=""
CUSTOM_TAG=""
TAG_SUFFIX=""
CUSTOM_TITLE=""
CUSTOM_NOTES_FILE=""
EXTRA_NOTES_FILE=""
FS_OVERRIDE="auto"
DETECTED_FS="unknown"
INCREMENTAL_ZIP_ARG=""
INCREMENTAL_ZIP=""
TARGET_FILES_ARG=""
TARGET_FILES_ZIP=""
BASELINE_URL="${OTA_BASELINE_URL:-}"
BASELINE_BASE_URL="${OTA_BASELINE_BASE_URL:-https://sourceforge.net/projects/cubot-marlon-rom-releases/files/ota-baselines}"
SF_DEST_DEFAULT="kelexine@frs.sourceforge.net:/home/frs/project/cubot-marlon-rom-releases/ota-baselines"
SF_DEST="${OTA_SF_DEST:-${SF_DEST_DEFAULT}}"
SKIP_SF=false
SF_UPLOAD_OK=false
SPLIT_BASELINE=false
OTA_JSON_OUT=""
OTA_JSON_PUSH_DIR="${OTA_RELEASES_DIR:-${HOME}/cubot-marlon-rom-releases}"
SKIP_OTA_PUSH=false
OTA_VARIANT="GMS"
IS_DRAFT=false
IS_PRERELEASE=false
DRY_RUN=false
FORCE_CLOBBER=true
SPLIT_PARTS=()

# Display usage instructions
show_help() {
    cat <<'EOF'
Smart, Idempotent GitHub Release Publisher for Cubot P50 (marlon)

Usage:
  ./push-release.sh [options] [product-out-directory]

Options:
  -d, --dir <path>             Path to product output directory containing built images.
  -r, --repo <owner/repo>      GitHub repository (default: kelexine/cubot-marlon-rom-releases).
  -t, --tag <tag>              Explicit release tag name (e.g. v2.9-20261115 or v2.9-20261115-r2).
  -s, --tag-suffix <suffix>    Append suffix to auto-generated tag (e.g. r2, test).
  -m, --title <title>          Release title heading.
  -n, --notes <file>           Custom markdown file to replace the entire release body.
  -a, --append-notes <file>    Append custom markdown notes while preserving generated highlights
                               and the SHA-256 asset checksums table.
      --fs <auto|erofs|ext4>   Override super partition filesystem detection (default: auto).
  -i, --incremental <file>     Incremental OTA zip (auto-discovered in product dir if omitted).
  -b, --target-files <file>    Target-files baseline zip (auto-checks ~/ota-baselines/).
      --baseline-url <url>     Explicit download URL for target_files in generated OTA JSON.
      --baseline-base-url <u>  Base URL directory used to construct target_files.url (SourceForge-aware).
      --sf-dest <rsync-dest>   SourceForge FRS rsync target (default: kelexine@frs.sourceforge.net:.../ota-baselines).
      --no-sf                  Skip SourceForge target-files baseline upload.
      --split-baseline         Split >1900MiB target-files.zip into <=1800MiB GitHub Release parts.
      --ota-json-out <file>    Output path for Updater JSON (default: <ota-repo>/OTA/<variant>/<rom>.json).
      --ota-json-push <dir>    Git checkout to commit (-s) & push OTA JSON (default: ~/cubot-marlon-rom-releases).
      --no-ota-push            Write OTA JSON locally without committing/pushing to cubot-marlon-rom-releases.
      --draft                  Publish as a draft release.
      --prerelease             Mark as pre-release.
      --dry-run                Simulate asset discovery, notes, and JSON generation without uploading.
  -h, --help                   Show this help message.

Discovery:
  If --dir is omitted, push-release.sh checks in order:
    1. $ANDROID_PRODUCT_OUT / $OUT
    2. Current working directory
    3. ${HOME}/axionos/out/target/product/marlon
    4. ${WORKSPACE_ROOT}/out/target/product/marlon
    5. Glob match for out/target/product/marlon
EOF
}

# Parse command line flags
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dir)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                PRODUCT_DIR="$2"
                shift 2
                ;;
            -r|--repo)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                TARGET_REPO="$2"
                shift 2
                ;;
            -t|--tag)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                CUSTOM_TAG="$2"
                shift 2
                ;;
            -s|--tag-suffix)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                TAG_SUFFIX="${2#-}"
                shift 2
                ;;
            -m|--title)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                CUSTOM_TITLE="$2"
                shift 2
                ;;
            -n|--notes)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                CUSTOM_NOTES_FILE="$2"
                shift 2
                ;;
            -a|--append-notes)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                EXTRA_NOTES_FILE="$2"
                shift 2
                ;;
            --fs)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                case "$2" in
                    auto|erofs|ext4) FS_OVERRIDE="$2" ;;
                    *) die "Invalid --fs value '$2' (expected auto, erofs, or ext4)." ;;
                esac
                shift 2
                ;;
            -i|--incremental)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                INCREMENTAL_ZIP_ARG="$2"
                shift 2
                ;;
            -b|--target-files)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                TARGET_FILES_ARG="$2"
                shift 2
                ;;
            --baseline-url)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                BASELINE_URL="$2"
                shift 2
                ;;
            --baseline-base-url)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                BASELINE_BASE_URL="$2"
                shift 2
                ;;
            --sf-dest)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                SF_DEST="$2"
                shift 2
                ;;
            --no-sf)
                SKIP_SF=true
                SF_DEST=""
                shift
                ;;
            --split-baseline)
                SPLIT_BASELINE=true
                shift
                ;;
            --ota-json-out)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                OTA_JSON_OUT="$2"
                shift 2
                ;;
            --ota-json-push)
                [[ -n "${2:-}" ]] || die "Option $1 requires an argument."
                OTA_JSON_PUSH_DIR="$2"
                shift 2
                ;;
            --no-ota-push)
                SKIP_OTA_PUSH=true
                OTA_JSON_PUSH_DIR=""
                shift
                ;;
            --draft)
                IS_DRAFT=true
                shift
                ;;
            --prerelease)
                IS_PRERELEASE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                if [[ -z "$1" ]]; then
                    shift
                elif [[ -z "${PRODUCT_DIR}" && -d "$1" ]]; then
                    PRODUCT_DIR="$1"
                    shift
                else
                    warn "Unrecognized option '$1' (ignored)"
                    shift
                fi
                ;;
        esac
    done
}

# Verify gh CLI and GitHub authentication
verify_environment() {
    if ! command -v gh >/dev/null 2>&1; then
        die "GitHub CLI ('gh') is required but not installed or not in PATH."
    fi

    if [[ "${DRY_RUN}" == "false" ]]; then
        if ! gh auth status >/dev/null 2>&1; then
            die "GitHub CLI is not authenticated. Please run 'gh auth login' or export GITHUB_TOKEN."
        fi
    fi
}

# Find valid Android product out directory
resolve_product_dir() {
    if [[ -n "${PRODUCT_DIR}" && -d "${PRODUCT_DIR}" ]]; then
        PRODUCT_DIR="$(cd "${PRODUCT_DIR}" && pwd)"
        return 0
    fi

    # Check environment variables
    if [[ -n "${ANDROID_PRODUCT_OUT:-}" && -d "${ANDROID_PRODUCT_OUT}" ]]; then
        PRODUCT_DIR="$(cd "${ANDROID_PRODUCT_OUT}" && pwd)"
        return 0
    fi

    if [[ -n "${OUT:-}" && -d "${OUT}" ]]; then
        PRODUCT_DIR="$(cd "${OUT}" && pwd)"
        return 0
    fi

    # Check current directory
    if compgen -G "./axion-*.zip" >/dev/null || compgen -G "./lineage-*.zip" >/dev/null || [[ -f "./boot.img" && -f "./recovery.img" ]]; then
        PRODUCT_DIR="$(pwd)"
        return 0
    fi

    # Check well-known server paths
    local candidates=(
        "${WORKSPACE_ROOT}/out/target/product/marlon"
        "${WORKSPACE_ROOT}/../out/target/product/marlon"
        "${WORKSPACE_ROOT}/../../out/target/product/marlon"
        "${HOME}/axionos/out/target/product/marlon"
        "${HOME}/lineage/out/target/product/marlon"
    )

    for cand in "${candidates[@]}"; do
        if [[ -d "${cand}" ]]; then
            PRODUCT_DIR="$(cd "${cand}" && pwd)"
            return 0
        fi
    done

    # Try searching for product output
    local found_dir
    found_dir="$(find "${WORKSPACE_ROOT}" -maxdepth 5 -type d -path '*/out/target/product/marlon' 2>/dev/null | head -n 1 || true)"
    if [[ -z "${found_dir}" && -d "${WORKSPACE_ROOT}/../.." ]]; then
        found_dir="$(find "${WORKSPACE_ROOT}/../.." -maxdepth 5 -type d -path '*/out/target/product/marlon' 2>/dev/null | head -n 1 || true)"
    fi
    if [[ -n "${found_dir}" && -d "${found_dir}" ]]; then
        PRODUCT_DIR="$(cd "${found_dir}" && pwd)"
        return 0
    fi

    die "Could not automatically locate the product output directory. Please specify with --dir <path>."
}

# Human readable file size helper
human_size() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        echo "0B"
        return
    fi
    numfmt --to=iec-i --suffix=B "$(stat -c%s "${file}")" 2>/dev/null || \
    ls -lh "${file}" | awk '{print $5}'
}

# Discover assets and compute SHA256 checksums
collect_assets() {
    log "Scanning product directory: ${PRODUCT_DIR}"
    cd "${PRODUCT_DIR}"

    UPLOAD_FILES=()
    PRIMARY_ZIP=""
    ROM_FLAVOR="generic"
    ROM_VERSION=""
    BUILD_DATE=""
    BUILD_TAG_SUGGESTION=""

    # 1. Detect ROM Zip
    local zip_candidates=()
    while IFS= read -r z; do
        [[ -n "${z}" ]] && zip_candidates+=("${z}")
    done < <(find . -maxdepth 1 -type f \( -name "axion-*.zip" -o -name "lineage-*.zip" -o -name "ofrp-*.zip" -o -name "twrp-*.zip" \) ! -name "*-ota.zip" ! -name "*-INCREMENTAL-*.zip" -printf "%f\n" | sort -r)

    ROM_TYPE_TAG="UNOFFICIAL"
    if [[ ${#zip_candidates[@]} -gt 0 ]]; then
        PRIMARY_ZIP="${zip_candidates[0]}"
        log "Found primary ROM zip: ${PRIMARY_ZIP}"
        UPLOAD_FILES+=("${PRIMARY_ZIP}")

        if [[ "${PRIMARY_ZIP}" =~ axion-([0-9.]+)-([A-Za-z0-9_]+)-([0-9]{8})-(.*)\.zip ]]; then
            ROM_FLAVOR="AxionOS"
            ROM_VERSION="${BASH_REMATCH[1]}"
            BUILD_DATE="${BASH_REMATCH[3]}"
            BUILD_TAG_SUGGESTION="v${ROM_VERSION}-${BUILD_DATE}"
            if [[ "${BASH_REMATCH[4]}" =~ ^(OFFICIAL|UNOFFICIAL|COMMUNITY)- ]]; then
                ROM_TYPE_TAG="${BASH_REMATCH[1]}"
            fi
        elif [[ "${PRIMARY_ZIP}" =~ lineage-([0-9.]+)-([0-9]{8})-(.*)\.zip ]]; then
            ROM_FLAVOR="LineageOS"
            ROM_VERSION="${BASH_REMATCH[1]}"
            BUILD_DATE="${BASH_REMATCH[2]}"
            BUILD_TAG_SUGGESTION="lineage-${ROM_VERSION}-${BUILD_DATE}"
        fi

        if [[ "${PRIMARY_ZIP}" =~ -(VANILLA|vanilla)- ]]; then
            OTA_VARIANT="VANILLA"
        else
            OTA_VARIANT="GMS"
        fi
    else
        warn "No ROM zip (axion-*.zip / lineage-*.zip) found in ${PRODUCT_DIR}. Proceeding with partition images only."
    fi

    # 1b. Detect or resolve incremental OTA zip
    INCREMENTAL_ZIP=""
    if [[ -n "${INCREMENTAL_ZIP_ARG}" ]]; then
        [[ -f "${INCREMENTAL_ZIP_ARG}" ]] || die "Incremental zip not found: ${INCREMENTAL_ZIP_ARG}"
        local incr_base
        incr_base="$(basename "${INCREMENTAL_ZIP_ARG}")"
        if [[ "$(cd "$(dirname "${INCREMENTAL_ZIP_ARG}")" && pwd)/${incr_base}" != "${PRODUCT_DIR}/${incr_base}" ]]; then
            cp -f "${INCREMENTAL_ZIP_ARG}" "./${incr_base}"
        fi
        INCREMENTAL_ZIP="${incr_base}"
    else
        local incr_candidate=""
        incr_candidate="$(find . -maxdepth 1 -type f \( -name "axion-*-INCREMENTAL-*.zip" -o -name "lineage-*-INCREMENTAL-*.zip" \) -printf "%f\n" | sort -r | head -n 1 || true)"
        [[ -n "${incr_candidate}" ]] && INCREMENTAL_ZIP="${incr_candidate}"
    fi
    if [[ -n "${INCREMENTAL_ZIP}" ]]; then
        log "Found incremental OTA zip: ${INCREMENTAL_ZIP}"
        UPLOAD_FILES+=("${INCREMENTAL_ZIP}")
    fi

    # 1c. Resolve target-files baseline zip (exact UTC match first, then date fallback)
    local build_utc=""
    for prop_candidate in \
        "${PRODUCT_DIR}/system/build.prop" \
        "${PRODUCT_DIR}/obj/PACKAGING/target_files_intermediates/lineage_marlon-target_files/SYSTEM/build.prop"; do
        if [[ -f "${prop_candidate}" ]]; then
            build_utc="$(grep -m1 '^ro\.build\.date\.utc=' "${prop_candidate}" | cut -d'=' -f2 | tr -d '\r\n' || true)"
            [[ -n "${build_utc}" ]] && break
        fi
    done

    TARGET_FILES_ZIP=""
    if [[ -n "${TARGET_FILES_ARG}" ]]; then
        [[ -f "${TARGET_FILES_ARG}" ]] || die "Target-files zip not found: ${TARGET_FILES_ARG}"
        TARGET_FILES_ZIP="$(cd "$(dirname "${TARGET_FILES_ARG}")" && pwd)/$(basename "${TARGET_FILES_ARG}")"
    elif [[ -n "${BUILD_DATE}" ]]; then
        if [[ -n "${build_utc}" && -f "${HOME}/ota-baselines/marlon-target_files-${BUILD_DATE}-${build_utc}.zip" ]]; then
            TARGET_FILES_ZIP="${HOME}/ota-baselines/marlon-target_files-${BUILD_DATE}-${build_utc}.zip"
        elif [[ -f "${HOME}/ota-baselines/marlon-target_files-${BUILD_DATE}.zip" ]]; then
            TARGET_FILES_ZIP="${HOME}/ota-baselines/marlon-target_files-${BUILD_DATE}.zip"
        fi
    fi

    SPLIT_PARTS=()
    if [[ -n "${TARGET_FILES_ZIP}" && "${SPLIT_BASELINE}" == "true" ]]; then
        local tf_bytes
        tf_bytes="$(stat -c%s "${TARGET_FILES_ZIP}")"
        local tf_base
        tf_base="$(basename "${TARGET_FILES_ZIP}")"
        if (( tf_bytes <= 1992294400 )); then
            if [[ "${DRY_RUN}" == "true" ]]; then
                log "[DRY-RUN] Would attach single target-files asset: ${tf_base}"
            else
                if [[ "$(dirname "${TARGET_FILES_ZIP}")" != "${PRODUCT_DIR}" ]]; then
                    cp -f "${TARGET_FILES_ZIP}" "./${tf_base}"
                fi
                UPLOAD_FILES+=("${tf_base}")
            fi
        elif [[ "${DRY_RUN}" == "true" ]]; then
            local est_parts=$(( (tf_bytes + 1887436800 - 1) / 1887436800 ))
            log "[DRY-RUN] Would split ${tf_base} ($(human_size "${TARGET_FILES_ZIP}")) into ~${est_parts} <=1.8GiB GitHub asset parts."
        else
            log "Splitting ${tf_base} ($(human_size "${TARGET_FILES_ZIP}")) into <=1.8GiB GitHub asset parts..."
            rm -f "./${tf_base}.part-"*
            split -b 1800M --additional-suffix="" "${TARGET_FILES_ZIP}" "./${tf_base}.part-"
            while IFS= read -r part; do
                [[ -n "${part}" ]] || continue
                SPLIT_PARTS+=("$(basename "${part}")")
                UPLOAD_FILES+=("$(basename "${part}")")
            done < <(find . -maxdepth 1 -type f -name "${tf_base}.part-*" | sort)
        fi
    fi

    # 2. Partition images
    local img_list=(
        "boot.img"
        "dtbo.img"
        "recovery.img"
        "vbmeta.img"
        "super_empty.img"
    )

    for img in "${img_list[@]}"; do
        if [[ -f "${img}" ]]; then
            UPLOAD_FILES+=("${img}")
        fi
    done

    # 3. Ensure checksums
    log "Computing / verifying SHA-256 checksums..."
    local sums_file="SHA256SUMS.txt"
    > "${sums_file}"

    for f in "${UPLOAD_FILES[@]}"; do
        local sha
        sha="$(sha256sum "${f}" | awk '{print $1}')"
        printf "%s  %s\n" "${sha}" "${f}" >> "${sums_file}"

        # Ensure standalone .sha256 exists for primary & incremental zips
        if [[ "${f}" == "${PRIMARY_ZIP}" || "${f}" == "${INCREMENTAL_ZIP}" ]]; then
            local zip_sha_file="${f}.sha256"
            printf "%s  %s\n" "${sha}" "${f}" > "${zip_sha_file}"
            UPLOAD_FILES+=("${zip_sha_file}")
        fi
    done

    UPLOAD_FILES+=("${sums_file}")

    log "Collected ${#UPLOAD_FILES[@]} files for release:"
    for f in "${UPLOAD_FILES[@]}"; do
        printf "  • %-45s (%s)\n" "${f}" "$(human_size "${f}")"
    done
}

# Detect super partition filesystem type (erofs vs ext4)
detect_filesystem() {
    if [[ "${FS_OVERRIDE}" != "auto" ]]; then
        DETECTED_FS="${FS_OVERRIDE}"
        return 0
    fi

    local probe_img=""
    for candidate in "system.img" "vendor.img" "product.img"; do
        if [[ -f "${PRODUCT_DIR}/${candidate}" ]]; then
            probe_img="${PRODUCT_DIR}/${candidate}"
            break
        fi
    done

    if [[ -n "${probe_img}" ]]; then
        local magic=""
        magic="$(od -An -tx1 -j 1024 -N 4 "${probe_img}" 2>/dev/null | tr -d ' \n' || true)"
        if [[ "${magic}" == "e2e1f5e0" ]]; then
            DETECTED_FS="erofs"
            return 0
        fi
        if command -v file >/dev/null 2>&1; then
            local file_desc=""
            file_desc="$(file -b "${probe_img}" 2>/dev/null || true)"
            if [[ "${file_desc}" == *"EROFS"* ]]; then
                DETECTED_FS="erofs"
                return 0
            elif [[ "${file_desc}" == *"ext4"* || "${file_desc}" == *"ext2"* ]]; then
                DETECTED_FS="ext4"
                return 0
            fi
        fi
        DETECTED_FS="ext4"
        return 0
    fi

    local fstab_path="${PRODUCT_DIR}/vendor/etc/fstab.mt6765"
    if [[ -f "${fstab_path}" ]]; then
        local first_fs=""
        first_fs="$(awk '$1 == "system" && $2 == "/system" {print $3; exit}' "${fstab_path}" 2>/dev/null || true)"
        if [[ "${first_fs}" == "erofs" || "${first_fs}" == "ext4" ]]; then
            DETECTED_FS="${first_fs}"
            return 0
        fi
    fi

    DETECTED_FS="unknown"
}

# Resolve release tag and title
resolve_release_info() {
    detect_filesystem

    if [[ -n "${CUSTOM_TAG}" ]]; then
        RELEASE_TAG="${CUSTOM_TAG}"
    else
        if [[ -n "${BUILD_TAG_SUGGESTION}" ]]; then
            RELEASE_TAG="${BUILD_TAG_SUGGESTION}"
        else
            RELEASE_TAG="v2.9-$(date +%Y%m%d)"
        fi

        if [[ -n "${TAG_SUFFIX}" ]]; then
            RELEASE_TAG="${RELEASE_TAG}-${TAG_SUFFIX}"
        fi
    fi

    if [[ -n "${CUSTOM_TITLE}" ]]; then
        RELEASE_TITLE="${CUSTOM_TITLE}"
    elif [[ "${ROM_FLAVOR}" == "AxionOS" ]]; then
        RELEASE_TITLE="AxionOS ${ROM_VERSION:-2.9} (NOESIS) – UNOFFICIAL for Cubot P50 (marlon)"
    elif [[ "${ROM_FLAVOR}" == "LineageOS" ]]; then
        RELEASE_TITLE="LineageOS ${ROM_VERSION:-23.2} – UNOFFICIAL for Cubot P50 (marlon)"
    else
        RELEASE_TITLE="Custom ROM Build for Cubot P50 (marlon) - ${RELEASE_TAG}"
    fi

    log "Target Repository: ${TARGET_REPO}"
    log "Filesystem:        ${DETECTED_FS}"
    log "Release Tag:       ${RELEASE_TAG}"
    log "Release Title:     ${RELEASE_TITLE}"
    log "Pre-release:       ${IS_PRERELEASE}"
    [[ -n "${TARGET_FILES_ZIP}" ]] && log "Target-Files ZIP:  ${TARGET_FILES_ZIP}"
}

# Generate rich markdown release notes
generate_release_notes() {
    NOTES_TMP="$(mktemp /tmp/release_notes_XXXXXX.md)"
    trap 'rm -f "${NOTES_TMP:-}"' EXIT

    if [[ -n "${CUSTOM_NOTES_FILE}" && -f "${CUSTOM_NOTES_FILE}" ]]; then
        log "Using custom release notes from ${CUSTOM_NOTES_FILE}"
        cp "${CUSTOM_NOTES_FILE}" "${NOTES_TMP}"
        return 0
    fi

    local fs_display="ext4"
    if [[ "${DETECTED_FS}" == "erofs" ]]; then
        fs_display="EROFS (\`lz4hc,9\`, 256KiB pcluster) + \`ext4\` fallback"
    elif [[ "${DETECTED_FS}" == "unknown" ]]; then
        fs_display="N/A"
    fi

    cat <<EOF > "${NOTES_TMP}"
### ${RELEASE_TITLE}

**Device:** Cubot P50 (\`marlon\`)
**Platform:** MediaTek MT6765 / MT6762 (Helio P35)
**Release Tag:** \`${RELEASE_TAG}\`
**Filesystem:** ${fs_display}
**Build Date:** $(date -u +'%Y-%m-%d %H:%M UTC')

---

### Highlights & Key Improvements

- **Kernel Linux 4.19.325 (CIP SLTS) Overhaul:**
  - **Syscall 436 (\`close_range\`):** Full upstream backport including \`CLOSE_RANGE_CLOEXEC\`, \`CLOSE_RANGE_UNSHARE\`, and syzbot race fixes. Resolves bionic \`posix_spawn\` failure (\`close_range(3, ~0U, CLOSE_RANGE_CLOEXEC)\`) and restores functional Wi-Fi Hotspot / Tethering (\`dnsmasq\`).
  - **Syscall 435 (\`clone3\`):** Modern fork syscall with \`copy_struct_from_user\` framework and \`CLONE_CLEAR_SIGHAND\` support.
  - **Syscall 438 (\`pidfd_getfd\`):** Process file-descriptor duplicate and transfer mechanism.
  - **Syscall 439 (\`faccessat2\`):** Modern access validation integrated with MTK \`inode_permission2\` VFS security framework.
  - **Syscall 440 (\`process_madvise\`):** External memory hinting API for modern Android memory daemons with arm64 32-bit compat plumbing.
  - **Syscall 441 (\`epoll_pwait2\`):** High-precision nanosecond epoll wait with 64-bit and compat 32-bit plumbing.
  - **Memory Management & ART CMC GC Support:**
    - **Syscall \`mremap(MREMAP_DONTUNMAP)\`:** Upstream backport for anonymous and shared memory (memfd/shmem), allowing Java heap physical pages to be remapped without unmapping the virtual address space.
    - **Userfaultfd Minor Faults (\`UFFDIO_CONTINUE\`):** Backported minor-fault registration (\`UFFDIO_REGISTER_MODE_MINOR\`) and continuation ioctl (\`UFFDIO_CONTINUE\`) for hugetlbfs and shmem, satisfying the kernel prerequisites for Android Runtime (ART) Concurrent Mark-Compact (CMC) Garbage Collection.
    - \`CONFIG_USERFAULTFD=y\`, \`CONFIG_MEMCG=y\`, \`CONFIG_MEMCG_SWAP=y\`, and \`CONFIG_PSI=y\` enabled for modern Android 15/16 memory isolation and \`lmkd\` pressure tracking.

- **Performance Profile HAL (\`Encore\`):**
  - Integrated frozen \`vendor.cubot.hardware.encore\` AIDL v1 service with VINTF manifest fragment and compatibility matrix.
  - Wired MT6765/MT6762 CPU/GPU OPP table telemetry, GED inverse level control, and FPSGO scheduling toggles with dedicated \`encore.te\` SELinux policy.

- **Gestures & Input (\`DT2W\` / \`KeyHandler\`):**
  - Added \`MarlonKeyHandler\` with \`overlay-lineage\` RRO config (\`config_device_supports_double_tap\`), \`mtk-tpd.kl\` wake key mapping, and \`DoubleTapToWakeController\` sync against \`Settings.Secure.DOUBLE_TAP_TO_WAKE\`.
  - Enabled lockscreen-safe wake, torch (\`TorchCallback\`), and camera keyguard launch actions via \`ActionUtils\`.

- **Audio & Dolby Atmos Subsystem:**
  - Resolved direct-branch linker undefined symbol in \`libshim_audio.so\` for \`audioPortConfigsToHal\`.
  - In-process Bluetooth Audio HAL provider with dynamic routing fallback.
  - **Dolby Atmos Audio System:** Patched 64-bit DAP audio effect (\`libswdap.so\`), \`libdlbdsservice.so\`, and \`libdlbpreg.so\` dynamic linker dependencies to link against \`libstagefright_foundation-v33.so\`.
  - Declared \`vendor.dolby.hardware.dms@2.0::IDms default\` in service init script and granted SELinux binder permissions for \`system_app\` (\`LunarisDolby\`) to communicate with \`hal_dms\`.

- **Storage & File System Stability:**
  - Enabled \`CONFIG_FUSE_FS=y\` and \`CONFIG_CUSE=y\` in \`marlon_defconfig\` for rock-solid userspace storage virtualization.
  - Aligned Android 16 storage parameters to eliminate dangling symlinks to \`/dev/null\` for internal storage (\`/sdcard\`).
EOF

    if [[ "${DETECTED_FS}" == "erofs" ]]; then
        cat <<'EOF' >> "${NOTES_TMP}"

- **EROFS Dynamic Partitions (Default):**
  - Read-only dynamic super partitions (`system`, `vendor`, `product`) use **EROFS** (`lz4hc,9`, `BOARD_EROFS_PCLUSTER_SIZE := 262144`) with secondary `ext4` fallback entries in `fstab.mt6765` and `fstab.mt6762`.
  - Uses kernel `4.19.325` supported EROFS features (`sb_csum`, `mtime`, `0padding`, `compr_cfgs`, `big_pcluster`).
EOF
    fi

    cat <<EOF >> "${NOTES_TMP}"

- **Kernel Toolchain & Module Compilation:**
  - Built with **Android NDK r30** (LLVM/Clang).
  - Consolidated MTK connectivity (\`wmt_drv\`, \`wmt_chrdev_wifi\`, \`wlan_drv_gen4m\`, \`bt_drv\`, \`gps_drv\`) and MET modules directly in-tree on \`marlon-cip\`, sequenced in \`vendor.img\`'s \`modules.load\`.
EOF

    if [[ -n "${EXTRA_NOTES_FILE}" ]]; then
        [[ -f "${EXTRA_NOTES_FILE}" ]] || die "Extra notes file not found: ${EXTRA_NOTES_FILE}"
        printf '\n---\n\n' >> "${NOTES_TMP}"
        cat "${EXTRA_NOTES_FILE}" >> "${NOTES_TMP}"
        printf '\n' >> "${NOTES_TMP}"
    fi

    cat <<EOF >> "${NOTES_TMP}"

---

### Flashing Instructions

#### Fastboot / Clean Install
\`\`\`bash
# 1. Unlock bootloader and reboot to bootloader
fastboot flash boot boot.img
fastboot flash dtbo dtbo.img
fastboot flash recovery recovery.img
fastboot flash vbmeta vbmeta.img --disable-verity --disable-verification

# 2. Reboot into recovery
fastboot reboot recovery
\`\`\`

#### Recovery (ADB Sideload)
1. In recovery, select **Factory Reset** -> **Format data / factory reset**.
2. Select **Apply update** -> **Apply from ADB**.
3. Sideload the full ROM zip:
\`\`\`bash
adb sideload ${PRIMARY_ZIP:-"rom.zip"}
\`\`\`
4. Reboot system.
EOF

    if [[ -n "${INCREMENTAL_ZIP}" ]]; then
        cat <<EOF >> "${NOTES_TMP}"

#### Incremental OTA Update (Existing Matching Baseline Only)
\`\`\`bash
adb sideload ${INCREMENTAL_ZIP}
\`\`\`
*(Or select **Local update** in Settings -> System -> Updater. Only applies cleanly on top of the exact matching prior baseline build without \`/system\`, \`/vendor\`, or \`/product\` modifications.)*
EOF
    fi

    cat <<EOF >> "${NOTES_TMP}"

---

### Asset Checksums (SHA-256)

| Asset File | Size | SHA-256 Checksum |
| :--- | :--- | :--- |
EOF

    for f in "${UPLOAD_FILES[@]}"; do
        local sha
        sha="$(sha256sum "${f}" | awk '{print $1}')"
        local sz
        sz="$(human_size "${f}")"
        printf "| \`%s\` | %s | \`%s\` |\n" "${f}" "${sz}" "${sha}" >> "${NOTES_TMP}"
    done

    cat <<'EOF' >> "${NOTES_TMP}"

*Verify all assets with:*
```bash
sha256sum -c SHA256SUMS.txt
```
EOF
}

# Publish release idempotently via gh CLI
publish_release() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] Would publish to GitHub repository: ${TARGET_REPO}"
        log "[DRY-RUN] Filesystem:    ${DETECTED_FS}"
        log "[DRY-RUN] Release Tag:   ${RELEASE_TAG}"
        log "[DRY-RUN] Release Title: ${RELEASE_TITLE}"
        log "[DRY-RUN] Pre-release:   ${IS_PRERELEASE}"
        log "[DRY-RUN] Draft:         ${IS_DRAFT}"
        log "[DRY-RUN] Generated Release Notes:"
        printf '%s\n' '--------------------------------------------------'
        cat "${NOTES_TMP}"
        printf '%s\n' '--------------------------------------------------'
        log "[DRY-RUN] Files that would be uploaded:"
        for f in "${UPLOAD_FILES[@]}"; do
            printf "  • %s\n" "${f}"
        done
        log "[DRY-RUN] Completed without modifying GitHub."
        return 0
    fi

    log "Checking if release '${RELEASE_TAG}' already exists on ${TARGET_REPO}..."

    local release_exists=false
    if gh release view "${RELEASE_TAG}" -R "${TARGET_REPO}" >/dev/null 2>&1; then
        release_exists=true
    fi

    if [[ "${release_exists}" == "true" ]]; then
        log "Release '${RELEASE_TAG}' already exists. Updating notes and uploading assets (idempotent update)..."

        gh release edit "${RELEASE_TAG}" \
            -R "${TARGET_REPO}" \
            --title "${RELEASE_TITLE}" \
            --notes-file "${NOTES_TMP}"

        log "Uploading/clobbering assets to existing release..."
        gh release upload "${RELEASE_TAG}" \
            -R "${TARGET_REPO}" \
            --clobber \
            "${UPLOAD_FILES[@]}"
    else
        log "Creating new release '${RELEASE_TAG}' on ${TARGET_REPO}..."
        local extra_flags=()
        [[ "${IS_DRAFT}" == "true" ]] && extra_flags+=("--draft")
        [[ "${IS_PRERELEASE}" == "true" ]] && extra_flags+=("--prerelease")

        gh release create "${RELEASE_TAG}" \
            -R "${TARGET_REPO}" \
            --title "${RELEASE_TITLE}" \
            --notes-file "${NOTES_TMP}" \
            ${extra_flags[@]+"${extra_flags[@]}"} \
            "${UPLOAD_FILES[@]}"
    fi

    local release_url
    release_url="$(gh release view "${RELEASE_TAG}" -R "${TARGET_REPO}" --json url -q .url 2>/dev/null || echo "https://github.com/${TARGET_REPO}/releases/tag/${RELEASE_TAG}")"
    log "=================================================="
    log "[+] Successfully published GitHub release!"
    log "[+] URL: ${release_url}"
    log "=================================================="
}

# Upload target-files baseline to SourceForge FRS via rsync if configured
upload_baseline_sourceforge() {
    SF_UPLOAD_OK=false
    if [[ "${SKIP_SF}" == "true" || "${SPLIT_BASELINE}" == "true" || -z "${SF_DEST}" ]]; then
        return 0
    fi
    if [[ -z "${TARGET_FILES_ZIP}" || ! -f "${TARGET_FILES_ZIP}" ]]; then
        warn "No target-files baseline zip found; skipping SourceForge upload."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        SF_UPLOAD_OK=true
        log "[DRY-RUN] Would rsync ${TARGET_FILES_ZIP} (+ .sha256) to SourceForge: ${SF_DEST}/"
        return 0
    fi

    command -v rsync >/dev/null 2>&1 || die "'rsync' is required for SourceForge upload (or pass --no-sf)."
    local sha_file="${TARGET_FILES_ZIP}.sha256"
    [[ -f "${sha_file}" ]] || sha256sum "${TARGET_FILES_ZIP}" > "${sha_file}"

    local sf_ssh="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=no"
    local -a sftp_opts=(-b /dev/null -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=no)
    if [[ -f "${HOME}/.ssh/sf_key" ]]; then
        sf_ssh="${sf_ssh} -i ${HOME}/.ssh/sf_key"
        sftp_opts+=(-i "${HOME}/.ssh/sf_key")
    fi

    # Ensure remote directory exists when targeting user@host:/path/leaf
    if command -v sftp >/dev/null 2>&1 && [[ "${SF_DEST}" == *:* ]]; then
        local sf_remote="${SF_DEST%%:*}"
        local sf_path="${SF_DEST#*:}"
        local sf_parent="${sf_path%/*}"
        local sf_leaf="${sf_path##*/}"
        if [[ -n "${sf_parent}" && -n "${sf_leaf}" ]]; then
            sftp "${sftp_opts[@]}" "${sf_remote}:${sf_parent}/" <<< "mkdir ${sf_leaf}" >/dev/null 2>&1 || true
        fi
    fi

    log "Uploading target-files baseline to SourceForge (${SF_DEST})..."
    if ! rsync -avh --partial --progress -e "${sf_ssh}" "${TARGET_FILES_ZIP}" "${sha_file}" "${SF_DEST}/"; then
        die "SourceForge upload failed. On a remote server, reconnect with 'ssh -A' to forward ~/.ssh/sf_key (or pass --no-sf). GitHub Release assets were preserved; re-run ./push-release.sh after fixing SSH."
    fi
    SF_UPLOAD_OK=true
    log "[+] Uploaded baseline to SourceForge: ${SF_DEST}/$(basename "${TARGET_FILES_ZIP}")"
}

ensure_ota_repo_ready() {
    local repo_dir="$1"
    local gh_cred='!gh auth git-credential'

    if [[ ! -d "${repo_dir}/.git" ]]; then
        log "Cloning ${TARGET_REPO} -> ${repo_dir}..."
        mkdir -p "$(dirname "${repo_dir}")"
        if ! git -c "credential.helper=${gh_cred}" clone "https://github.com/${TARGET_REPO}.git" "${repo_dir}"; then
            die "Failed to clone ${TARGET_REPO} into ${repo_dir}."
        fi
    elif [[ -z "$(git -C "${repo_dir}" status --porcelain 2>/dev/null)" ]]; then
        log "Syncing ${repo_dir} with origin/main..."
        git -C "${repo_dir}" -c "credential.helper=${gh_cred}" pull --ff-only origin main || \
            warn "Could not fast-forward ${repo_dir}; proceeding cautiously."
    fi

    if [[ -z "$(git -C "${repo_dir}" config user.name || true)" ]]; then
        local g_name=""
        g_name="$(gh api user -q '.name // .login' 2>/dev/null || true)"
        [[ -n "${g_name}" ]] && git -C "${repo_dir}" config user.name "${g_name}"
    fi
    if [[ -z "$(git -C "${repo_dir}" config user.email || true)" ]]; then
        local g_email=""
        g_email="$(gh api user/emails -q 'map(select(.primary and .verified)) | .[0].email // empty' 2>/dev/null || true)"
        if [[ -z "${g_email}" ]]; then
            g_email="$(gh api user -q '"\(.id)+\(.login)@users.noreply.github.com"' 2>/dev/null || true)"
        fi
        [[ -n "${g_email}" ]] && git -C "${repo_dir}" config user.email "${g_email}"
    fi
}

# Generate and optionally commit/push Axion Updater JSON
write_ota_json() {
    [[ -n "${PRIMARY_ZIP}" && -f "${PRODUCT_DIR}/${PRIMARY_ZIP}" ]] || return 0

    local json_filename="marlon.json"
    local rom_slug="rom"
    case "${ROM_FLAVOR}" in
        AxionOS)
            json_filename="axion.json"
            rom_slug="axion"
            ;;
        LineageOS)
            json_filename="lineage.json"
            rom_slug="lineage"
            ;;
    esac

    local push_dir=""
    if [[ "${SKIP_OTA_PUSH}" != "true" && -n "${OTA_JSON_PUSH_DIR}" ]]; then
        push_dir="${OTA_JSON_PUSH_DIR}"
        [[ "${DRY_RUN}" == "true" ]] || ensure_ota_repo_ready "${push_dir}"
    fi

    local json_out="${OTA_JSON_OUT}"
    if [[ -z "${json_out}" ]]; then
        if [[ -n "${push_dir}" ]]; then
            json_out="${push_dir}/OTA/${OTA_VARIANT}/${json_filename}"
        else
            json_out="${PRODUCT_DIR}/${json_filename}"
        fi
    fi

    local parts_joined=""
    if [[ ${#SPLIT_PARTS[@]} -gt 0 ]]; then
        parts_joined="$(printf '%s\n' "${SPLIT_PARTS[@]}")"
    fi

    local resolved_tf_url="${BASELINE_URL}"
    if [[ -z "${resolved_tf_url}" && "${SPLIT_BASELINE}" != "true" && "${SF_UPLOAD_OK}" == "true" && -n "${BASELINE_BASE_URL}" && -n "${TARGET_FILES_ZIP}" ]]; then
        local tf_name
        tf_name="$(basename "${TARGET_FILES_ZIP}")"
        if [[ "${BASELINE_BASE_URL}" == *"sourceforge.net"* ]]; then
            resolved_tf_url="${BASELINE_BASE_URL%/}/${tf_name}/download"
        else
            resolved_tf_url="${BASELINE_BASE_URL%/}/${tf_name}"
        fi
    fi

    local json_payload
    json_payload="$(python3 - \
        "${PRODUCT_DIR}" "${PRIMARY_ZIP}" "${TARGET_REPO}" "${RELEASE_TAG}" \
        "${ROM_VERSION:-2.9}" "${ROM_TYPE_TAG:-UNOFFICIAL}" \
        "${INCREMENTAL_ZIP}" "${TARGET_FILES_ZIP}" "${resolved_tf_url}" "${parts_joined}" <<'PY'
import hashlib, json, pathlib, re, sys, time

(
    product_dir, primary_zip, repo, tag,
    version, romtype, incr_zip, tf_zip, tf_url, parts_raw
) = sys.argv[1:]

pdir = pathlib.Path(product_dir)
primary_path = pdir / primary_zip

def md5_file(p: pathlib.Path) -> str:
    h = hashlib.md5()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def sha256_file(p: pathlib.Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

build_utc = None
for prop_path in [pdir / "system/build.prop", pdir / "obj/PACKAGING/target_files_intermediates/lineage_marlon-target_files/SYSTEM/build.prop"]:
    if prop_path.is_file():
        for line in prop_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("ro.build.date.utc="):
                build_utc = int(line.split("=", 1)[1].strip())
                break
    if build_utc is not None:
        break
if build_utc is None:
    build_utc = int(time.time())

base_url = f"https://github.com/{repo}/releases/download/{tag}"
entry = {
    "datetime": build_utc,
    "filename": primary_zip,
    "id": md5_file(primary_path),
    "romtype": romtype,
    "size": primary_path.stat().st_size,
    "url": f"{base_url}/{primary_zip}",
    "version": version,
}

if incr_zip and (pdir / incr_zip).is_file():
    ipath = pdir / incr_zip
    m = re.search(r"-(\d{8})-to-(\d{8})-INCREMENTAL-", incr_zip)
    entry["incremental"] = {
        "base_date": m.group(1) if m else "",
        "target_date": m.group(2) if m else "",
        "filename": incr_zip,
        "id": md5_file(ipath),
        "size": ipath.stat().st_size,
        "sha256": sha256_file(ipath),
        "url": f"{base_url}/{incr_zip}",
    }

if tf_zip and pathlib.Path(tf_zip).is_file():
    tf_path = pathlib.Path(tf_zip)
    sha_sidecar = pathlib.Path(str(tf_path) + ".sha256")
    if sha_sidecar.is_file():
        tf_sha = sha_sidecar.read_text(encoding="utf-8").strip().split()[0]
    else:
        tf_sha = sha256_file(tf_path)

    tf_meta = {
        "filename": tf_path.name,
        "size": tf_path.stat().st_size,
        "sha256": tf_sha,
        "url": tf_url or "",
    }
    part_names = [line.strip() for line in parts_raw.splitlines() if line.strip()]
    if part_names:
        tf_meta["parts"] = [
            {
                "filename": pname,
                "size": (pdir / pname).stat().st_size,
                "sha256": sha256_file(pdir / pname),
                "url": f"{base_url}/{pname}",
            }
            for pname in part_names
            if (pdir / pname).is_file()
        ]
    elif not tf_url and tf_path.name in [x.name for x in pdir.iterdir()]:
        tf_meta["url"] = f"{base_url}/{tf_path.name}"

    entry["target_files"] = tf_meta

print(json.dumps({"response": [entry]}, indent=2))
PY
)"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] Would write OTA JSON (${json_out}) [variant: ${OTA_VARIANT}]:"
        printf '%s\n' "${json_payload}"
        return 0
    fi

    mkdir -p "$(dirname "${json_out}")"
    printf '%s\n' "${json_payload}" > "${json_out}"
    log "[+] Wrote OTA JSON (${OTA_VARIANT}): ${json_out}"

    if [[ "${json_out}" != "${PRODUCT_DIR}/${json_filename}" ]]; then
        printf '%s\n' "${json_payload}" > "${PRODUCT_DIR}/${json_filename}"
    fi
    if [[ -d "${HOME}/ota-baselines" && "$(cd "$(dirname "${json_out}")" && pwd)/$(basename "${json_out}")" != "${HOME}/ota-baselines/${json_filename}" ]]; then
        printf '%s\n' "${json_payload}" > "${HOME}/ota-baselines/${json_filename}"
        log "[+] Mirrored OTA JSON: ${HOME}/ota-baselines/${json_filename}"
    fi

    if [[ -n "${push_dir}" ]]; then
        [[ -d "${push_dir}/.git" ]] || die "--ota-json-push directory is not a git repo: ${push_dir}"
        local rel_json
        rel_json="$(realpath --relative-to="${push_dir}" "${json_out}" 2>/dev/null || true)"
        [[ -n "${rel_json}" && "${rel_json}" != ../* ]] || die "--ota-json-out (${json_out}) must be inside --ota-json-push (${push_dir})."
        if ! git -C "${push_dir}" diff --quiet -- "${rel_json}" || [[ -n "$(git -C "${push_dir}" status --porcelain -- "${rel_json}")" ]]; then
            git -C "${push_dir}" add "${rel_json}"
            git -C "${push_dir}" commit -s -m "ota(${rom_slug}): update ${RELEASE_TAG} (${OTA_VARIANT}) manifest"
            git -C "${push_dir}" -c "credential.helper=!gh auth git-credential" push origin HEAD:main
            log "[+] Committed and pushed updated OTA JSON in ${push_dir} (${rel_json})"
        else
            log "OTA JSON unchanged in ${push_dir}; skipping git commit."
        fi
    fi
}

main() {
    parse_args "$@"
    verify_environment
    resolve_product_dir
    collect_assets
    resolve_release_info
    generate_release_notes
    publish_release
    upload_baseline_sourceforge
    write_ota_json
}

main "$@"
