#!/bin/bash
# Build both Mac and iOS apps
# Usage: ./build_all.sh [mac-config] [ios-device-id]
#   mac-config: debug (default) or release
#   ios-device-id: optional, auto-detects if not provided
set -e

cd "$(dirname "$0")"

MAC_CONFIG="${1:-debug}"
IOS_DEVICE_ID="$2"

echo "═══════════════════════════════════════"
echo "  Building metastream apps"
echo "═══════════════════════════════════════"
echo ""

# Build Mac app
echo "📱 Building Mac app ($MAC_CONFIG)..."
./build_and_run_mac.sh "$MAC_CONFIG" || {
    echo "❌ Mac build failed"
    exit 1
}

echo ""
echo "───────────────────────────────────────"
echo ""

# Build iOS app
echo "📱 Building iOS app..."
if [ -n "$IOS_DEVICE_ID" ]; then
    ./build_and_install_ios.sh "$IOS_DEVICE_ID" || {
        echo "❌ iOS build/install failed"
        exit 1
    }
else
    ./build_and_install_ios.sh || {
        echo "❌ iOS build/install failed"
        exit 1
    }
fi

echo ""
echo "═══════════════════════════════════════"
echo "✅ All builds complete!"
echo "═══════════════════════════════════════"
