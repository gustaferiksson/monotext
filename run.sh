#!/bin/bash
# Build monotext and launch it as a minimal .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$ROOT/.build/MonoText.app"

echo "› building"
swift build --package-path "$ROOT" -c debug

echo "› bundling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$ROOT/.build/debug/monotext" "$BUNDLE/Contents/MacOS/monotext"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MonoText</string>
  <key>CFBundleDisplayName</key><string>MonoText</string>
  <key>CFBundleExecutable</key><string>monotext</string>
  <key>CFBundleIdentifier</key><string>dev.gustaf.monotext</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
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

pkill -x monotext 2>/dev/null || true
open -n "$BUNDLE"
