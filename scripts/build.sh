#!/bin/zsh
# Release build with SwiftPM (needs Xcode 26.3+, selected via xcode-select), then wrap the app
# executable into MacWallpaper.app (menu-bar app: LSUIElement, ad-hoc signed).
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=.build/MacWallpaper.app
mkdir -p $APP/Contents/MacOS
cp $BIN/WallpaperApp $APP/Contents/MacOS/MacWallpaper
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.macwallpaper.app</string>
  <key>CFBundleName</key><string>MacWallpaper</string>
  <key>CFBundleExecutable</key><string>MacWallpaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - $APP >/dev/null 2>&1 || true
echo "built $BIN/wecli and $APP"
