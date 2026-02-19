#!/bin/bash
# Build Release metaStreamMac.app and copy to output/ folder
# Usage: ./build_mac_release.sh
set -e
cd "$(dirname "$0")"
echo "🔨 Building metaStreamMac (Release)..."
xcodebuild -scheme metaStreamMac -configuration Release -destination 'platform=macOS' build -quiet
BUILD_DIR=$(xcodebuild -scheme metaStreamMac -configuration Release -showBuildSettings 2>/dev/null | grep " BUILT_PRODUCTS_DIR =" | sed 's/.*= //')
APP_PATH="$BUILD_DIR/metaStreamMac.app"
mkdir -p output
rm -rf output/metaStreamMac.app
cp -R "$APP_PATH" output/
echo "✅ Done. Executable: output/metaStreamMac.app"
echo "   Run with: open output/metaStreamMac.app"
