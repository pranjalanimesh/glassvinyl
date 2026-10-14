#!/bin/sh
# Builds GlassVinyl.app (menu-bar only, no Dock icon) from the Swift package.
#   ./build.sh          build and sign GlassVinyl.app
#   ./build.sh --zip    also write dist/GlassVinyl.zip for a release
# VERSION sets the app version (default 0.1.0).
set -e
cd "$(dirname "$0")"
VERSION="${VERSION:-0.1.0}"

swift build -c release
APP=GlassVinyl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GlassVinyl "$APP/Contents/MacOS/GlassVinyl"
cp Resources/bridge.js Resources/install-karaoke.sh Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.pranjalanimesh.glassvinyl</string>
  <key>CFBundleName</key><string>GlassVinyl</string>
  <key>CFBundleExecutable</key><string>GlassVinyl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>GlassVinyl listens to audio output to draw the visualizer.</string>
  <key>NSAppleEventsUsageDescription</key><string>GlassVinyl reads and controls the YouTube Music tab in Brave.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP $VERSION. Run: open $APP"

if [ "$1" = "--zip" ]; then
  mkdir -p dist
  rm -f dist/GlassVinyl.zip
  ditto -c -k --keepParent "$APP" dist/GlassVinyl.zip
  echo "Wrote dist/GlassVinyl.zip"
fi
