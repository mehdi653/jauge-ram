#!/bin/bash
# Compile Jauge RAM et fabrique le bundle .app (sans Xcode, uniquement les Command Line Tools).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Jauge RAM"
BINARY="JaugeRAM"
BUNDLE_ID="com.mehdi.jaugeram"
APP="build/${APP_NAME}.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compilation…"
swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework UserNotifications \
  -o "$APP/Contents/MacOS/$BINARY" \
  Sources/*.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleExecutable</key><string>${BINARY}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <!-- Français si le Mac est en français, anglais sinon (voir Sources/Localization.swift) -->
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- Agent : présent uniquement dans la barre des menus, pas dans le Dock -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "→ Traductions…"
cp -R Resources/*.lproj "$APP/Contents/Resources/"

echo "→ Signature ad-hoc…"
codesign --force --deep --sign - "$APP"

echo "✓ Construit : $(pwd)/$APP"
