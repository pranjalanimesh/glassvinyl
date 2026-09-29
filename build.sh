#!/bin/sh
# Builds YTPlayer.app (menu-bar only, no Dock icon) from the Swift package.
set -e
cd "$(dirname "$0")"

swift build -c release
APP=YTPlayer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/YTPlayer "$APP/Contents/MacOS/YTPlayer"
cp Resources/bridge.js "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.pranjal.ytplayer</string>
  <key>CFBundleName</key><string>YTPlayer</string>
  <key>CFBundleExecutable</key><string>YTPlayer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>YTPlayer listens to audio output to draw the visualizer.</string>
  <key>NSAppleEventsUsageDescription</key><string>YTPlayer reads and controls the YouTube Music tab in Brave.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP — run: open $APP"
