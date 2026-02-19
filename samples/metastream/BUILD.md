# Build & Run Guide

Streamlined scripts for building and running metastream apps.

## Quick Start

### Mac App

**Build and run (Debug):**
```bash
cd samples/metastream
./build_and_run_mac.sh
```

**Build and run (Release):**
```bash
./build_and_run_mac.sh release
```

**Build Release and copy to output/:**
```bash
./build_mac_release.sh
```

### iOS App

**Build and install on connected iPhone (auto-detect device):**
```bash
cd samples/metastream
./build_and_install_ios.sh
```

**Build and install on specific device:**
```bash
./build_and_install_ios.sh <DEVICE_ID>
```

To find your iPhone's device ID:
```bash
xcrun xctrace list devices
```

### Build Both Apps

**Build Mac (debug) and iOS apps:**
```bash
./build_all.sh
```

**Build Mac (release) and iOS apps:**
```bash
./build_all.sh release
```

**Build with specific iOS device:**
```bash
./build_all.sh debug <DEVICE_ID>
```

## Scripts Overview

| Script | Purpose |
|--------|---------|
| `build_and_run_mac.sh` | Build and launch Mac app (Debug/Release) |
| `build_and_install_ios.sh` | Build and install iOS app on connected iPhone |
| `build_mac_release.sh` | Build Release Mac app and copy to `output/` |
| `build_all.sh` | Build both Mac and iOS apps |

## Manual Build Commands

If you prefer manual control:

**Mac:**
```bash
xcodebuild -scheme metaStreamMac -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/metastream-*/Build/Products/Debug/metaStreamMac.app
```

**iOS:**
```bash
# Build
xcodebuild -scheme metastream-ios -configuration Debug -destination 'id=<DEVICE_ID>' build

# Install
xcrun devicectl device install app --device <DEVICE_ID> \
  ~/Library/Developer/Xcode/DerivedData/metastream-*/Build/Products/Debug-iphoneos/metastream-ios.app
```

## Troubleshooting

**iOS: "No connected iPhone found"**
- Ensure iPhone is connected via USB
- Unlock iPhone and tap "Trust This Computer"
- Check with: `xcrun xctrace list devices`

**iOS: "Signing requires a development team"**
- Open project in Xcode
- Select project → metastream-ios target
- Signing & Capabilities → Select your Team

**Mac: App won't launch**
- Check Console.app for errors
- Ensure virtual camera extension is enabled in System Settings → Privacy & Security
