#!/bin/bash
# Build and run metaStreamMac app
# Usage: ./build_and_run_mac.sh [debug|release]
set -e

cd "$(dirname "$0")"
CONFIG="${1:-debug}"
CONFIG_UPPER=$(echo "$CONFIG" | tr '[:lower:]' '[:upper:]')

echo "🔨 Building metaStreamMac ($CONFIG_UPPER)..."
xcodebuild -scheme metaStreamMac -configuration "$CONFIG_UPPER" -destination 'platform=macOS' build -quiet

BUILD_DIR=$(xcodebuild -scheme metaStreamMac -configuration "$CONFIG_UPPER" -showBuildSettings 2>/dev/null | grep " BUILT_PRODUCTS_DIR =" | sed 's/.*= //')
APP_PATH="$BUILD_DIR/metaStreamMac.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: App not found at $APP_PATH"
    exit 1
fi

echo "✅ Build complete"
echo "🚀 Launching metaStreamMac.app..."
open "$APP_PATH"
