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

set -eo pipefail

# --- Color formatting helpers ---
log()   { printf '\033[1;32m[push-release]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[push-release]\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m[push-release]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# --- Defaults ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${SCRIPT_DIR}"
DEFAULT_REPO="kelexine/android_device_cubot_marlon"
TARGET_REPO="${DEFAULT_REPO}"
PRODUCT_DIR=""
CUSTOM_TAG=""
CUSTOM_TITLE=""
CUSTOM_NOTES_FILE=""
IS_DRAFT=false
IS_PRERELEASE=false
DRY_RUN=false
FORCE_CLOBBER=true

# Display usage instructions
show_help() {
    cat <<'EOF'
Smart, Idempotent GitHub Release Publisher for Cubot P50 (marlon)

Usage:
  ./push-release.sh [options] [product-out-directory]

Options:
  -d, --dir <path>          Path to product output directory containing built images.
  -r, --repo <owner/repo>   GitHub repository (default: kelexine/android_device_cubot_marlon).
  -t, --tag <tag>           Explicit release tag name (e.g. v2.9-20261024 or v2.9-20261024-r2).
  -m, --title <title>       Release title heading.
  -n, --notes <file>        Custom markdown file to use as release notes.
      --draft               Publish as a draft release.
      --prerelease          Mark as pre-release.
      --dry-run             Simulate asset discovery and notes generation without uploading.
  -h, --help                Show this help message.

Discovery:
  If --dir is omitted, push-release.sh checks in order:
    1. $ANDROID_PRODUCT_OUT / $OUT
    2. Current working directory
    3. /serverhive4/kelexine/axionos/out/target/product/marlon
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
        "/serverhive4/kelexine/axionos/out/target/product/marlon"
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
    done < <(find . -maxdepth 1 -type f \( -name "axion-*.zip" -o -name "lineage-*.zip" -o -name "ofrp-*.zip" -o -name "twrp-*.zip" \) ! -name "*-ota.zip" -printf "%f\n" | sort -r)

    if [[ ${#zip_candidates[@]} -gt 0 ]]; then
        PRIMARY_ZIP="${zip_candidates[0]}"
        log "Found primary ROM zip: ${PRIMARY_ZIP}"
        UPLOAD_FILES+=("${PRIMARY_ZIP}")

        if [[ "${PRIMARY_ZIP}" =~ axion-([0-9.]+)-([A-Za-z0-9_]+)-([0-9]{8})-(.*)\.zip ]]; then
            ROM_FLAVOR="AxionOS"
            ROM_VERSION="${BASH_REMATCH[1]}"
            local codename="${BASH_REMATCH[2]}"
            BUILD_DATE="${BASH_REMATCH[3]}"
            BUILD_TAG_SUGGESTION="v${ROM_VERSION}-${BUILD_DATE}"
        elif [[ "${PRIMARY_ZIP}" =~ lineage-([0-9.]+)-([0-9]{8})-(.*)\.zip ]]; then
            ROM_FLAVOR="LineageOS"
            ROM_VERSION="${BASH_REMATCH[1]}"
            BUILD_DATE="${BASH_REMATCH[2]}"
            BUILD_TAG_SUGGESTION="lineage-${ROM_VERSION}-${BUILD_DATE}"
        fi
    else
        warn "No ROM zip (axion-*.zip / lineage-*.zip) found in ${PRODUCT_DIR}. Proceeding with partition images only."
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

        # If primary zip, ensure .sha256 file exists alongside it
        if [[ "${f}" == "${PRIMARY_ZIP}" ]]; then
            local zip_sha_file="${PRIMARY_ZIP}.sha256"
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

# Resolve release tag and title
resolve_release_info() {
    if [[ -n "${CUSTOM_TAG}" ]]; then
        RELEASE_TAG="${CUSTOM_TAG}"
    elif [[ -n "${BUILD_TAG_SUGGESTION}" ]]; then
        RELEASE_TAG="${BUILD_TAG_SUGGESTION}"
    else
        RELEASE_TAG="v2.9-$(date +%Y%m%d)"
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
    log "Release Tag:       ${RELEASE_TAG}"
    log "Release Title:     ${RELEASE_TITLE}"
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

    cat <<EOF > "${NOTES_TMP}"
### ${RELEASE_TITLE}

**Device:** Cubot P50 (\`marlon\`)
**Platform:** MediaTek MT6765 / MT6762 (Helio P35)
**Release Tag:** \`${RELEASE_TAG}\`
**Build Date:** $(date -u +'%Y-%m-%d %H:%M UTC')

---

### Highlights & Key Improvements

- **Kernel Linux 4.19.127 Overhaul:**
  - **Syscall 436 (\`close_range\`):** Full upstream backport including \`CLOSE_RANGE_CLOEXEC\`, \`CLOSE_RANGE_UNSHARE\`, and syzbot race fixes. Resolves bionic \`posix_spawn\` failure (\`close_range(3, ~0U, CLOSE_RANGE_CLOEXEC)\`) and restores functional Wi-Fi Hotspot / Tethering (\`dnsmasq\`).
  - **Syscall 435 (\`clone3\`):** Modern fork syscall with \`copy_struct_from_user\` framework and \`CLONE_CLEAR_SIGHAND\` support.
  - **Syscall 438 (\`pidfd_getfd\`):** Process file-descriptor duplicate and transfer mechanism.
  - **Syscall 439 (\`faccessat2\`):** Modern access validation integrated with MTK \`inode_permission2\` VFS security framework.
  - **Syscall 440 (\`process_madvise\`):** External memory hinting API for modern Android memory daemons with arm64 32-bit compat plumbing.
  - **Syscall 441 (\`epoll_pwait2\`):** High-precision nanosecond epoll wait with 64-bit and compat 32-bit plumbing.
  - **Memory Management & ART CMC GC Support:**
    - **Syscall \`mremap(MREMAP_DONTUNMAP)\`:** Upstream backport for anonymous and shared memory (memfd/shmem), allowing Java heap physical pages to be remapped without unmapping the virtual address space.
    - **Userfaultfd Minor Faults (\`UFFDIO_CONTINUE\`):** Backported minor-fault registration (\`UFFDIO_REGISTER_MODE_MINOR\`) and continuation ioctl (\`UFFDIO_CONTINUE\`) for hugetlbfs and shmem, satisfying the kernel prerequisites for Android Runtime (ART) Concurrent Mark-Compact (CMC) Garbage Collection.
    - \`CONFIG_USERFAULTFD=y\`: Enables userfaultfd subsystem and \`HAVE_ARCH_USERFAULTFD_MINOR\`.
    - \`CONFIG_MEMCG=y\` & \`CONFIG_MEMCG_SWAP=y\`: Full memory control groups for Android 15/16 memory isolation.
    - \`CONFIG_PSI=y\`: Pressure Stall Information enabled for precise \`lmkd\` low-memory management.

- **Audio Subsystem & HAL Shims:**
  - Resolved direct-branch linker undefined symbol in \`libshim_audio.so\` for \`audioPortConfigsToHal\`.
  - In-process Bluetooth Audio HAL provider with dynamic routing fallback.

- **Out-of-Tree Connectivity Modules:**
  - Compiled and staged inline via NDK r29 LLVM Clang: \`wmt_drv\`, \`wmt_chrdev_wifi\`, \`wlan_drv_gen4m\`, \`bt_drv\`, \`gps_drv\`, \`met\`.
  - Strictly sequenced in dependency order inside \`vendor.img\`'s \`modules.load\`.

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
3. Sideload the ROM zip:
\`\`\`bash
adb sideload ${PRIMARY_ZIP:-"rom.zip"}
\`\`\`
4. Reboot system.

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
        log "[DRY-RUN] Release Tag:   ${RELEASE_TAG}"
        log "[DRY-RUN] Release Title: ${RELEASE_TITLE}"
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
            "${extra_flags[@]}" \
            "${UPLOAD_FILES[@]}"
    fi

    local release_url
    release_url="$(gh release view "${RELEASE_TAG}" -R "${TARGET_REPO}" --json url -q .url 2>/dev/null || echo "https://github.com/${TARGET_REPO}/releases/tag/${RELEASE_TAG}")"
    log "=================================================="
    log "[+] Successfully published GitHub release!"
    log "[+] URL: ${release_url}"
    log "=================================================="
}

main() {
    parse_args "$@"
    verify_environment
    resolve_product_dir
    collect_assets
    resolve_release_info
    generate_release_notes
    publish_release
}

main "$@"
