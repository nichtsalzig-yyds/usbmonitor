#!/bin/bash
set -euo pipefail
BUILD_CACHE="${TMPDIR:-/private/tmp}/usb-drive-monitor-build"
mkdir -p "$BUILD_CACHE/clang" "$BUILD_CACHE/swiftpm"
SWIFTPM_CONFIG_DIR="$BUILD_CACHE/swiftpm" \
CLANG_MODULE_CACHE_PATH="$BUILD_CACHE/clang" \
swift build -c release
APP_DIR="${PWD}/USBDriveMonitor.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/USBDriveMonitor "$APP_DIR/Contents/MacOS/USBDriveMonitor"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>USB Drive Monitor</string>
<key>CFBundleDisplayName</key><string>USB Drive Monitor</string>
<key>CFBundleIdentifier</key><string>local.codex.usb-drive-monitor</string>
<key>CFBundleExecutable</key><string>USBDriveMonitor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "Built: $APP_DIR"
