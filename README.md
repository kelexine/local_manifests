# Cubot P50 (marlon) Local Manifests

> Local manifests repository for syncing and building LineageOS, AxionOS, and TWRP recovery for the Cubot P50 (marlon).

## What is this?
This repository provides the `.repo/local_manifests` configurations required to sync device trees, proprietary vendor blobs, and recovery configurations for the **Cubot P50** (`marlon` / `v956`, MediaTek MT6765). It supports LineageOS 23.2 (Android 16 baseline), LineageOS 19.1 (legacy Android 12 baseline), AxionOS (built on the axion branch), and TWRP 12.1.

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
./setup.sh axion axion ~/rom/axion      # explicit workspace directory
```

Run `./setup.sh --help` for the full list of supported ROM/branch combinations. The script is idempotent — re-running it against an existing workspace re-checks the manifest wiring and re-syncs rather than starting over.

## Features
- **LineageOS 23.2 Support**: Direct sync mapping for `device/cubot/marlon` and `vendor/cubot/marlon` on branch `lineage-23.2`.
- **AxionOS Support**: Direct sync mapping for `device/cubot/marlon` on branch `axion`, sharing vendor blobs with `lineage-23.2` (blobs are ROM-agnostic; only the device tree's build/product layer differs for AxionOS).
- **TWRP 12.1 Integration**: Direct sync mapping for `device/cubot/marlon` targeting TWRP 12.1.
- **One-command setup**: `setup.sh` on `main` automates repo-init, manifest selection, and sync for any supported ROM/branch combination.

## Manifest Files

| File | Target | Device Branch |
| :--- | :--- | :--- |
| `axion.xml` ⭐ | AxionOS | `axion` |
| `lineage-23.2.xml` | LineageOS 23.2 | `lineage-23.2` |
| `lineage-19.1.xml` | LineageOS 19.1 | `lineage-19.1` |
| `twrp-12.1.xml` | TWRP 12.1 | `marlon-12.1` |

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

## Architecture

| Target | Manifest File | Target Path | Remote / Upstream Repository | Revision |
| :--- | :--- | :--- | :--- | :--- |
| **AxionOS Device** | `axion.xml` | `device/cubot/marlon` | `kelexine/android_device_cubot_marlon` | `axion` |
| **AxionOS Vendor** | `axion.xml` | `vendor/cubot/marlon` | `kelexine/android_vendor_cubot_marlon` | `lineage-23.2` (shared) |
| **LineageOS 23.2 Device** | `lineage-23.2.xml` | `device/cubot/marlon` | `kelexine/android_device_cubot_marlon` | `lineage-23.2` |
| **LineageOS 23.2 Vendor** | `lineage-23.2.xml` | `vendor/cubot/marlon` | `kelexine/android_vendor_cubot_marlon` | `lineage-23.2` |
| **TWRP 12.1 Recovery** | `twrp-12.1.xml` | `device/cubot/marlon` | `kelexine/twrp_device_cubot_marlon` | `marlon-12.1` |
| **LineageOS 19.1 Device** | `lineage-19.1.xml` | `device/cubot/marlon` | `kelexine/android_device_cubot_marlon` | `lineage-19.1` |
| **LineageOS 19.1 Vendor** | `lineage-19.1.xml` | `vendor/cubot/marlon` | `kelexine/android_vendor_cubot_marlon` | `lineage-19.1` |
| **Kernel Source** | All manifests | `kernel/cubot/marlon` | `kelexine/android_kernel_oppo_mt6765` | `marlon-bringup` |

All targets also pull `LineageOS/android_device_mediatek_sepolicy_vndr` (on `lineage-23.2`) into `device/mediatek/sepolicy_vndr`.

### Kernel Toolchain (Android NDK r29)
The kernel compiles with LLVM/Clang from Android NDK r29. `setup.sh` automatically downloads and verifies the NDK at `~/Android/Ndk/android-ndk-r29` and generates `${WORKSPACE_DIR}/kernel-env.sh`. Source this script before starting your ROM build to export `TARGET_KERNEL_CLANG_PATH` and LLVM cross-compilation flags.

## Contributing
- Follow Conventional Commits: `<type>(<scope>): <summary>`
- Branch naming: `<type>/<short-slug>`
- Sign-off all commits with developer identity (`git commit -s`)

## License
- SPDX-License-Identifier: Apache-2.0
