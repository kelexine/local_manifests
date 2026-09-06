# Cubot P50 (marlon) Local Manifests

> Local manifests repository for syncing and building LineageOS and TWRP recovery for the Cubot P50 (marlon).

## What is this?
This repository provides the `.repo/local_manifests` configurations required to sync device trees, proprietary vendor blobs, and recovery configurations for the **Cubot P50** (`marlon` / `v956`, MediaTek MT6765/MT6762). It supports both LineageOS 23.2 (Android 16 baseline), LineageOS 19.1 (legacy Android 12 baseline), and TWRP 12.1.

## Features
- **LineageOS 23.2 Support**: Direct sync mapping for `device/cubot/marlon` and `vendor/cubot/marlon` on branch `lineage-23.2`.
- **TWRP 12.1 Integration**: Direct sync mapping for `device/cubot/marlon` targeting TWRP 12.1.
- **Direct Clone Branching**: Pre-configured target branches (`lineage-23.2`, `twrp-12.1`) for direct cloning into `.repo/local_manifests` without file conflicts.

## Installation

Within an initialized ROM or TWRP repo workspace, clone the appropriate branch into `.repo/local_manifests`:

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

## Usage

Alternatively, if cloning the `main` branch:

```bash
git clone https://github.com/kelexine/local_manifests .repo/local_manifests

# Choose your target by copying/linking the appropriate manifest as marlon.xml:
# For LineageOS 23.2:
cp .repo/local_manifests/lineage-23.2.xml .repo/local_manifests/marlon.xml
rm .repo/local_manifests/*.xml~ .repo/local_manifests/twrp-*.xml .repo/local_manifests/lineage-*.xml

# Sync workspace
repo sync -j$(nproc)
```

## Architecture

| Target | Manifest File | Target Path | Remote / Upstream Repository | Revision |
| :--- | :--- | :--- | :--- | :--- |
| **LineageOS 23.2 Device** | `lineage-23.2.xml` | `device/cubot/marlon` | `kelexine/android_device_cubot_marlon` | `lineage-23.2` |
| **LineageOS 23.2 Vendor** | `lineage-23.2.xml` | `vendor/cubot/marlon` | `kelexine/android_vendor_cubot_marlon` | `lineage-23.2` |
| **TWRP 12.1 Recovery** | `twrp-12.1.xml` | `device/cubot/marlon` | `kelexine/twrp_device_cubot_p50` | `marlon-12.1` |
| **LineageOS 19.1 Device** | `lineage-19.1.xml` | `device/cubot/marlon` | `kelexine/android_device_cubot_marlon` | `lineage-19.1` |
| **LineageOS 19.1 Vendor** | `lineage-19.1.xml` | `vendor/cubot/marlon` | `kelexine/android_vendor_cubot_marlon` | `lineage-19.1` |

## Contributing
- Follow Conventional Commits: `<type>(<scope>): <summary>`
- Branch naming: `<type>/<short-slug>`
- Sign-off all commits with developer identity (`git commit -s`)

## License
- SPDX-License-Identifier: Apache-2.0
