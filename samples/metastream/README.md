# metastream Sample Apps

Sample iOS and macOS applications demonstrating video streaming from Meta AI glasses to Mac as a virtual camera.

## Apps

### metastream-ios (iOS)

Connects to Ray-Ban Meta glasses, displays the camera feed, and streams video to the Mac companion app over your local network.

**Features:**
- Connect to Meta AI glasses via Bluetooth
- Display live camera feed
- Capture photos
- Stream video to Mac companion via H.264 over UDP
- Automatic Mac discovery via Bonjour

### metaStreamMac (macOS)

Receives video stream from the iOS app and exposes it as a virtual camera available to all macOS applications.

**Features:**
- Automatic iPhone discovery via Bonjour
- H.264 hardware decoding
- Virtual camera extension (CMIOExtension)
- Works with Zoom, FaceTime, Google Meet, OBS, etc.

## Prerequisites

- iOS 17.0+ / macOS 14.0+
- Xcode 15+
- Meta Wearables Device Access Toolkit
- Ray-Ban Meta glasses with developer mode enabled
- Meta AI app installed on iPhone
- Both devices on the same local network

## Building

### iOS App

1. Open `metastream.xcodeproj` in Xcode
2. Select the `metastream-ios` scheme
3. Configure your Meta credentials in `Info.plist`
4. Build and run on your iPhone

### Mac App

1. Open `metastream.xcodeproj` in Xcode
2. Select the `metaStreamMac` scheme
3. Build and run

## Setup for Contributors

Before building, you'll need to:
1. Replace the bundle identifier (`org.metastream.*`) with your own
2. Add your development team in Xcode signing settings
3. Configure your Meta developer credentials in Info.plist

## Usage

1. Turn on Developer Mode in the Meta AI app
2. Launch the iOS app and tap "Connect" to pair with your glasses
3. Launch the Mac app - it will automatically discover the iPhone
4. Open any video app and select "metastream Camera" as your camera source

## Troubleshooting

**iPhone not discovered by Mac:**
- Ensure both devices are on the same network
- Check Local Network permission in System Settings
- Verify Bonjour is advertising: `dns-sd -B _metastream._udp local.`

**Virtual camera not appearing:**
- Run the Mac app at least once
- Check System Settings > Privacy > Camera
- Verify the CMIOExtension is properly signed

**Can't connect to glasses:**
- Ensure glasses are in developer mode
- Check Meta AI app is installed and logged in
- Verify Info.plist credentials match Meta developer portal

## License

See the [LICENSE](../../LICENSE) file in the root directory.
