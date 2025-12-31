# metastream

Stream video from your Ray-Ban Meta glasses to your Mac as a virtual camera.

metastream lets you use your Ray-Ban Meta glasses as a webcam in any macOS application - Zoom, FaceTime, Google Meet, OBS, and more. The glasses stream video to your iPhone, which relays it over your local network to a Mac companion app that exposes it as a system camera.

## How It Works

```
Ray-Ban Meta Glasses
        ↓ Bluetooth
iPhone (metastream iOS)
        ↓ H.264 over UDP (local network)
Mac (metastream Mac)
        ↓ Virtual Camera Extension
Zoom / FaceTime / Any App
```

## Features

- Low-latency video streaming (~100ms end-to-end)
- Hardware H.264 encoding/decoding for efficiency
- Automatic device discovery via Bonjour
- Works with any app that uses macOS cameras

## Requirements

- Ray-Ban Meta glasses with developer mode enabled
- iPhone with iOS 17.0+ and Meta AI app installed
- Mac with macOS 14.0+
- Both devices on the same local network
- [Meta Wearables developer account](https://wearables.developer.meta.com/)

## Getting Started

### 1. Set Up Meta Developer Credentials

1. Create an account at [Meta Wearables Developer Center](https://wearables.developer.meta.com/)
2. Create a new project and note your credentials
3. Add your credentials to the iOS app's `Info.plist`:
   - `MetaAppID`
   - `ClientToken`
   - `AppLinkURLScheme`

### 2. Build and Run

**iOS App:**
```bash
xcodebuild -project samples/metastream/metastream.xcodeproj \
  -scheme metastream-ios \
  -destination 'platform=iOS,id=YOUR_DEVICE_ID' \
  build
```

**Mac App:**
```bash
xcodebuild -project samples/metastream/metastream.xcodeproj \
  -scheme metaStreamMac \
  -destination 'platform=macOS' \
  build
```

### 3. Connect and Stream

1. Launch the iOS app and connect to your glasses
2. Launch the Mac app - it will automatically discover the iPhone
3. Open any video app and select "metastream Camera" as your camera source

## Project Structure

```
samples/metastream/
├── metastream-ios/          # iOS app - connects to glasses, streams video
├── metaStreamMac/          # Mac app - receives video, manages virtual camera
└── Shared/metastreamRelay/ # Shared networking and video codec code
```

## Attribution

This project is built on [Meta Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios). By using this software, you agree to the [Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms).

## License

See [LICENSE](LICENSE) file. This project uses the Meta Wearables Device Access Toolkit which has its own licensing terms.
