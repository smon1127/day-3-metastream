# metastream

Stream video from your Ray-Ban Meta glasses to your Mac as a virtual camera — or broadcast it to any NDI receiver on your network.

metastream lets you use your Ray-Ban Meta glasses as a webcam in any macOS application — Zoom, FaceTime, Google Meet, OBS, and more. The glasses stream video to your iPhone, which relays it over your local network to a Mac companion app that exposes it as a system camera. You can also broadcast the video feed directly via **NDI** to any compatible receiver (OBS, TouchDesigner, vMix, Wirecast, etc.).

## How It Works

```
Ray-Ban Meta Glasses
        ↓ Bluetooth
iPhone (metastream iOS)
        ├─→ H.264 over UDP ──→ Mac (metastream Mac) ──→ Virtual Camera ──→ Zoom / FaceTime / Any App
        └─→ NDI over Wi-Fi ──→ OBS / TouchDesigner / vMix / Any NDI Receiver
```

## Features

- Low-latency video streaming (~100ms end-to-end)
- Hardware H.264 encoding/decoding for efficiency
- **NDI broadcast** — stream directly to any NDI receiver on your network
- Automatic device discovery via Bonjour
- Works with any app that uses macOS cameras
- Build scripts for fast iteration

## Requirements

- Ray-Ban Meta glasses with developer mode enabled
- iPhone with iOS 17.0+ and Meta AI app installed
- Mac with macOS 14.0+
- Both devices on the same local network
- [Meta Wearables developer account](https://wearables.developer.meta.com/)
- [NDI SDK for Apple](https://ndi.video/for-developers/ndi-sdk/) (for NDI broadcast feature)

## Getting Started

### 1. Set Up Meta Developer Credentials

1. Create an account at [Meta Wearables Developer Center](https://wearables.developer.meta.com/)
2. Create a new project and note your credentials
3. Add your credentials to `metastream-ios/Info.plist` under the `MWDAT` key:
   - `MetaAppID` — your Meta App ID
   - `ClientToken` — your client token
4. Set your development team in Xcode (Signing & Capabilities) or in `project.pbxproj`

### 2. Install NDI SDK (optional, for NDI broadcast)

1. Download and install the [NDI SDK for Apple](https://ndi.video/for-developers/ndi-sdk/) from the official NDI developer page
2. The SDK installs to `/Library/NDI SDK for Apple/` — the Xcode project references this path automatically
3. The iOS app links against `libndi_ios.a` (static library) included in the SDK

### 3. Build and Run

**Quick start with scripts:**

```bash
cd samples/metastream

# Build and run the Mac app
./build_and_run_mac.sh

# Build and install the iOS app on your connected iPhone
./build_and_install_ios.sh

# Build both at once
./build_all.sh
```

**Or manually:**

```bash
# Mac app
xcodebuild -scheme metaStreamMac -destination 'platform=macOS' build

# iOS app (find your device ID with: xcrun xctrace list devices)
xcodebuild -scheme metastream-ios -destination 'id=YOUR_DEVICE_ID' build
```

### 4. Connect and Stream

1. Launch the iOS app and connect to your glasses
2. Launch the Mac app — it will automatically discover the iPhone
3. Open any video app and select "metastream Camera" as your camera source

### 5. NDI Broadcast (optional)

1. While streaming, tap the relay button (desktop icon) in the iOS app
2. Toggle **Broadcast via NDI** on
3. The stream appears as an NDI source on your local network
4. Open any NDI receiver (OBS, TouchDesigner, vMix, NDI Studio Monitor) and select the source

## Project Structure

```
samples/metastream/
├── metastream-ios/              # iOS app — connects to glasses, streams video
│   ├── Views/                   # SwiftUI views (StreamView, RelayMessagesSheet, etc.)
│   ├── ViewModels/              # Stream session, device management
│   └── Info.plist               # Meta credentials, permissions, Bonjour services
├── metaStreamMac/               # Mac app — receives video, virtual camera
├── Shared/metastreamRelay/      # Shared code
│   ├── StreamBroadcaster.swift  # UDP relay to Mac
│   ├── NDIBroadcaster.swift     # NDI video sender
│   ├── PacketTypes.swift        # Network protocol
│   └── Video/                   # H.264 encoder/decoder (VideoToolbox)
├── build_and_run_mac.sh         # Build + launch Mac app
├── build_and_install_ios.sh     # Build + install iOS app on device
├── build_all.sh                 # Build both apps
└── build_mac_release.sh         # Release build to output/
```

## Build Scripts

| Script | Purpose |
|--------|---------|
| `build_and_run_mac.sh [debug\|release]` | Build and launch Mac app |
| `build_and_install_ios.sh [device-id]` | Build and install iOS app (auto-detects device) |
| `build_all.sh [config] [device-id]` | Build both apps |
| `build_mac_release.sh` | Release build copied to `output/` |

## Setup for Contributors

Before building, you'll need to:

1. Add your Meta developer credentials to `Info.plist` (see step 1 above)
2. Set your development team in Xcode under Signing & Capabilities
3. Install the [NDI SDK for Apple](https://ndi.video/for-developers/ndi-sdk/) if you want NDI support
4. Ensure your iPhone and Mac are on the same local network

## Troubleshooting

**iPhone not discovered by Mac:**
- Ensure both devices are on the same network
- Check Local Network permission in Settings > Privacy
- Verify Bonjour: `dns-sd -B _metastream._udp local.`

**NDI source not visible on network:**
- Ensure the iPhone and receiver are on the same Wi-Fi network
- Check Local Network permission is enabled for metastream
- Verify NDI discovery: `dns-sd -B _ndi._tcp local.`
- Kill and relaunch the app after first install

**Virtual camera not appearing:**
- Run the Mac app at least once
- Check System Settings > Privacy > Camera
- Verify the CMIOExtension is properly signed

**Can't connect to glasses:**
- Ensure glasses are in developer mode
- Check Meta AI app is installed and logged in
- Verify Info.plist credentials match Meta developer portal

## Attribution

This project is built on [Meta Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios). NDI is a registered trademark of [Vizrt NDI AB](https://ndi.video/). By using this software, you agree to the [Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms) and the [NDI SDK License](https://ndi.video/sdk/license/).

## License

See [LICENSE](LICENSE) file. This project uses the Meta Wearables Device Access Toolkit and NDI SDK which have their own licensing terms.
