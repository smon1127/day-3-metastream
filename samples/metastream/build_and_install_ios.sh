#!/bin/bash
# Build and install metastream-ios app on connected iPhone
# Usage: ./build_and_install_ios.sh [device-id]
set -e

cd "$(dirname "$0")"

# Auto-detect connected iPhone if device ID not provided
if [ -z "$1" ]; then
    echo "🔍 Detecting connected iPhone..."
    DEVICE_ID=$(xcrun xctrace list devices 2>/dev/null | grep -E "iPhone|iPad" | grep -v "Simulator" | head -1 | grep -oE "\([0-9A-F-]{40}\)" | tr -d '()')
    
    if [ -z "$DEVICE_ID" ]; then
        echo "❌ Error: No connected iPhone found"
        echo "   Connect your iPhone via USB and ensure it's trusted"
        echo "   Or specify device ID: ./build_and_install_ios.sh <DEVICE_ID>"
        exit 1
    fi
    
    DEVICE_NAME=$(xcrun xctrace list devices 2>/dev/null | grep "$DEVICE_ID" | sed 's/ (.*//')
    echo "📱 Found device: $DEVICE_NAME ($DEVICE_ID)"
else
    DEVICE_ID="$1"
    echo "📱 Using device: $DEVICE_ID"
fi

echo "🔨 Building metastream-ios (Debug)..."
xcodebuild -scheme metastream-ios -configuration Debug -destination "id=$DEVICE_ID" build -quiet

BUILD_DIR=$(xcodebuild -scheme metastream-ios -configuration Debug -showBuildSettings 2>/dev/null | grep " BUILT_PRODUCTS_DIR =" | sed 's/.*= //')
APP_PATH="$BUILD_DIR/metastream-ios.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: App not found at $APP_PATH"
    exit 1
fi

echo "📦 Installing app on device..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1 | grep -E "(installed|Error|error)" || true

echo "✅ Installation complete!"
echo "   The app should appear on your iPhone home screen"
echo "   If first time, trust the developer in Settings → General → VPN & Device Management"
