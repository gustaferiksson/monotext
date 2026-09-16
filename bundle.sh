#!/bin/bash
# Assemble .build/MonoText.app from an already-built executable.
# Usage: [VERSION=1.2.3] [BUILD=7] ./bundle.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-debug}"
VERSION="${VERSION:-0.0.1}"
BUILD="${BUILD:-1}"
BUNDLE="$ROOT/.build/MonoText.app"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$ROOT/.build/$CONFIG/monotext" "$BUNDLE/Contents/MacOS/monotext"
cp "$ROOT/icon/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MonoText</string>
  <key>CFBundleDisplayName</key><string>MonoText</string>
  <key>CFBundleExecutable</key><string>monotext</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>dev.gustaf.monotext</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Plain Text</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.plain-text</string>
        <string>public.text</string>
        <string>public.source-code</string>
      </array>
      <key>NSDocumentClass</key><string>monotext.Document</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Any File</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.data</string>
      </array>
      <key>NSDocumentClass</key><string>monotext.Document</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "› bundled $BUNDLE"
