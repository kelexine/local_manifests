# Cubot P50 (marlon) Local Manifests

> Local manifests repository for syncing and building LineageOS, AxionOS, TWRP, and OrangeFox Recovery for the Cubot P50 (marlon).

## What is this?
This repository provides the `.repo/local_manifests` configurations required to sync device trees, proprietary vendor blobs, and recovery configurations for the **Cubot P50** (`marlon` / `v956`, MediaTek MT6765). It supports LineageOS 23.2 (Android 16 baseline), LineageOS 19.1 (legacy Android 12 baseline), AxionOS (built on the axion branch), TWRP 12.1, and OrangeFox Recovery Project 12.1.

## Quick Start: `setup.sh`

The fastest way to get building is the included setup script, which handles `repo init`, wiring up this local manifests repo, and `repo sync` in one command:

```bash
curl -sL https://raw.githubusercontent.com/kelexine/local_manifests/main/setup.sh -o setup.sh
chmod +x setup.sh
./setup.sh <rom> [branch] [workspace_dir]
```

Examples:
```bash
./setup.sh lineage                      # LineageOS, default branch (23.2)
./setup.sh lineage 19.1                 # LineageOS 19.1
./setup.sh axion                        # AxionOS (axion branch)
./setup.sh twrp                         # TWRP recovery
./setup.sh ofrp                         # OrangeFox recovery (fox_12.1)
./setup.sh axion axion ~/rom/axion      # explicit workspace directory
```

Run `./setup.sh --help` for the full list of supported ROM/branch combinations. The script is idempotent — re-running it against an existing workspace re-checks the manifest wiring and re-syncs rather than starting over.

## Features
- **LineageOS 23.2 Support**: Direct sync mapping for `device/cubot/marlon` and `vendor/cubot/marlon` on branch `lineage-23.2`.
- **AxionOS Support**: Direct sync mapping for `device/cubot/marlon` on branch `axion`, sharing vendor blobs with `lineage-23.2` (blobs are ROM-agnostic; only the device tree's build/product layer differs for AxionOS).
- **TWRP 12.1 Integration**: Direct sync mapping for `device/cubot/marlon` targeting TWRP 12.1.
- **OrangeFox 12.1 Integration**: Direct sync mapping for `device/cubot/marlon` targeting OrangeFox `fox_12.1` (`ofox_marlon`).
- **One-command setup**: `setup.sh` on `main` automates repo-init, manifest selection, and sync for any supported ROM/branch combination.

## Manifest Files

| File | Target | Device Branch |
| :--- | :--- | :--- |
| `axion.xml` ⭐ | AxionOS | `axion` |
| `lineage-23.2.xml` | LineageOS 23.2 | `lineage-23.2` |
| `lineage-19.1.xml` | LineageOS 19.1 | `lineage-19.1` |
| `twrp-12.1.xml` | TWRP 12.1 | `marlon-12.1` |
| `ofrp-12.1.xml` | OrangeFox 12.1 | `main` |

## Manual Installation

Within an initialized ROM or TWRP repo workspace, clone the appropriate branch into `.repo/local_manifests`:

### For AxionOS
```bash
repo init -u https://github.com/AxionAOSP/android.git -b axion --git-lfs
git clone https://github.com/kelexine/local_manifests .repo/local_manifests
cp .repo/local_manifests/axion.xml .repo/local_manifests/marlon.xml
rm .repo/local_manifests/lineage-*.xml .repo/local_manifests/twrp-*.xml
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune -j$(nproc)
```

### For LineageOS 23.2
```bash
git clone https://github.com/kelexine/local_manifests -b lineage-23.2 .repo/local_manifests
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune -j$(nproc)
```

### For TWRP 12.1
```bash
git clone https://github.com/kelexine/local_manifests -b twrp-12.1 .repo/local_manifests
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune -j$(nproc)
```

### For OrangeFox 12.1
```bash
git clone https://github.com/kelexine/local_manifests -b main .repo/local_manifests
cp .repo/local_manifests/ofrp-12.1.xml .repo/local_manifests/marlon.xml
repo sync -c --no-clone-bundle --no-tags --optimized-fetch --prune -j$(nproc)
```

## Architecture

| Target | Manifest File | Target Path | Remote / Upstream Repository | Revision |
| :--- | :--- | :--- | :--- | :--- |
| **AxionOS Device** | `axion.xml` | `device/cubot/marlon` | `kelexine/android_device_cubot_marlon` | `axion` |
| **AxionOS Vendor** | `axion.xml` | `vendor/cubot/marlon` | `kelexine/android_vendor_cubot_marlon` | `lineage-23.2` (shared) |
| **LineageOS 23.2 Device** | `lineage-23.2.xml` | `device/cubot/marlon` | `kelexine/android_device_cubot_marlon` | `lineage-23.2` |
| **LineageOS 23.2 Vendor** | `lineage-23.2.xml` | `vendor/cubot/marlon` | `kelexine/android_vendor_cubot_marlon` | `lineage-23.2` |
| **TWRP 12.1 Recovery** | `twrp-12.1.xml` | `device/cubot/marlon` | `kelexine/twrp_device_cubot_marlon` | `marlon-12.1` |
| **OrangeFox 12.1 Recovery** | `ofrp-12.1.xml` | `device/cubot/marlon` | `kelexine/ofrp_device_cubot_marlon` | `main` |
| **LineageOS 19.1 Device** | `lineage-19.1.xml` | `device/cubot/marlon` | `kelexine/android_device_cubot_marlon` | `lineage-19.1` |
| **LineageOS 19.1 Vendor** | `lineage-19.1.xml` | `vendor/cubot/marlon` | `kelexine/android_vendor_cubot_marlon` | `lineage-19.1` |
| **Kernel Source** | All manifests | `kernel/cubot/marlon` | `kelexine/android_kernel_cubot_mt6765` | `marlon-cip` |

All targets also pull `LineageOS/android_device_mediatek_sepolicy_vndr` (on `lineage-23.2`) into `device/mediatek/sepolicy_vndr`.

### Kernel Toolchain (Android NDK r30)
The kernel compiles with LLVM/Clang from Android NDK r30. `setup.sh` automatically downloads and verifies the NDK at `~/Android/Ndk/android-ndk-r30` and generates `${WORKSPACE_DIR}/kernel-env.sh`. Source this script before starting your ROM build to export `TARGET_KERNEL_CLANG_PATH` and LLVM cross-compilation flags.

## Publishing Releases: `push-release.sh`

An automated, idempotent GitHub release script is included to publish ROM builds, upload baselines, and push Updater manifests in one command (or automatically via `./build.sh -r`):

```bash
./push-release.sh [options] [out/target/product/marlon]
```

- **Zero-Flag Automation:** Running `./push-release.sh` automatically publishes GitHub Release assets (`kelexine/cubot-marlon-rom-releases`), uploads the `target-files` baseline + `.sha256` to SourceForge FRS (`ota-baselines`), detects `GMS` vs `VANILLA`, updates `~/cubot-marlon-rom-releases/OTA/{variant}/{rom}.json`, commits (`-s`), and pushes to `main`.
- **Idempotent:** Re-running against an existing tag updates release notes and clobbers/updates assets cleanly without duplicating or failing (so if a SourceForge upload fails without `ssh -A`, simply reconnect with `ssh -A` and re-run `./push-release.sh`).
- **Smart Discovery:** Automatically detects ROM zip (`axion-*.zip`, `lineage-*.zip`), optional incremental OTA zip (`*-INCREMENTAL-*.zip`), companion partition images (`boot.img`, `dtbo.img`, `recovery.img`, `vbmeta.img`, `super_empty.img`), UTC-matched target-files baseline (`~/ota-baselines/marlon-target_files-*.zip`), and generates/verifies SHA-256 checksums (`SHA256SUMS.txt`).
- **Options:**
  - `-d, --dir <path>`: Target product directory.
  - `-r, --repo <owner/repo>`: GitHub repository (defaults to `kelexine/cubot-marlon-rom-releases`).
  - `-t, --tag <tag>`: Custom tag name (auto-detected if omitted).
  - `-s, --tag-suffix <suffix>`: Optional suffix appended to auto-generated tags (e.g. `r2`).
  - `-m, --title <title>`: Custom release title.
  - `-n, --notes <file>`: Custom markdown file replacing the release body.
  - `-a, --append-notes <file>`: Append custom notes while keeping highlights and SHA-256 checksums.
  - `--fs <auto|erofs|ext4>`: Override super partition filesystem auto-detection (EROFS is default).
  - `-i, --incremental <file>`: Incremental OTA zip to attach alongside the full ROM zip.
  - `-b, --target-files <file>`: Target-files baseline zip to track in generated OTA JSON (`axion.json` / `lineage.json`).
  - `--baseline-url <url>` / `--baseline-base-url <url>`: Target-files download URL (defaults to `cubot-marlon-rom-releases` SourceForge `ota-baselines`) written to OTA JSON.
  - `--sf-dest <rsync-dest>` / `--no-sf`: SourceForge FRS rsync upload target (defaults to `kelexine@frs.sourceforge.net:/home/frs/project/cubot-marlon-rom-releases/ota-baselines`; use `--no-sf` to skip).
  - `--split-baseline`: Split `>1900 MiB` `target-files.zip` into `<=1800 MiB` GitHub Release parts.
  - `--ota-json-out <file>` / `--ota-json-push <git-dir>` / `--no-ota-push`: Override or disable automatic commit & push to `~/cubot-marlon-rom-releases`.
  - `--prerelease` / `--draft`: Mark the release as pre-release or draft.
  - `--dry-run`: Preview assets, release notes, and generated OTA JSON without uploading.

### Zero-Flag Build & Release Workflow (`setup.sh` -> `build.sh` -> `push-release.sh`)
```bash
# 1. Fresh server setup (syncs tree, NDK, certs, git/gh auth, clones cubot-marlon-rom-releases)
./setup.sh axion

# 2. Build ROM + archive baseline + resolve prior baseline via OTA JSON + generate incremental OTA
cd axion && ./build.sh

#    Or build + automatically publish GitHub Release + SourceForge baseline + OTA JSON in one shot:
./build.sh -r

# 3. Or publish separately after building (pass ssh -A on remote servers for SourceForge FRS):
./push-release.sh
```
Pass `--no-incremental`, `--no-sf`, or `--no-ota-push` to opt out of any automated stage.

## Contributing
- Follow Conventional Commits: `<type>(<scope>): <summary>`
- Branch naming: `<type>/<short-slug>`
- Sign-off all commits with developer identity (`git commit -s`)

## License
- SPDX-License-Identifier: Apache-2.0
