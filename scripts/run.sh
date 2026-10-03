#!/bin/bash
set -eu
cd "$(dirname "$0")/.."

echo "Building..."
swift build 2>&1

BINARY=".build/debug/Diskette"
APP_BUNDLE="Diskette.app"

if [ ! -f "$BINARY" ]; then
    echo "Build failed." >&2
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/Diskette"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Diskette</string>
    <key>CFBundleIdentifier</key>
    <string>com.diskette.app</string>
    <key>CFBundleName</key>
    <string>Diskette</string>
    <key>LSBackgroundOnly</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

echo "Launching Diskette..."
open "$APP_BUNDLE"
