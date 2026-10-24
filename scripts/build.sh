#!/bin/zsh
# Release build with SwiftPM (needs Xcode 26.3+, selected via xcode-select), then wrap the app
# executable into MacWallpaper.app (menu-bar app: LSUIElement). Signed with an Apple Development identity if there is
# one, else "mac-wallpaper development" (scripts/setup-signing.sh), else ad-hoc.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=${VERSION:-$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)}
VERSION=${VERSION:-0.0.0-dev}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=.build/MacWallpaper.app
mkdir -p $APP/Contents/MacOS
cp $BIN/WallpaperApp $APP/Contents/MacOS/MacWallpaper
# Translations (Localizable.strings per language) go into the bundle's Resources.
mkdir -p $APP/Contents/Resources
rsync -a --delete --include '*/' --include '*.strings' --exclude '*' Sources/WallpaperApp/Resources/ $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.macwallpaper.app</string>
  <key>CFBundleName</key><string>MacWallpaper</string>
  <key>CFBundleExecutable</key><string>MacWallpaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# An Apple Development certificate (free Apple ID in Xcode) carries a team ID: the Keychain then keeps
# granting access across rebuilds. Without one, macOS keys Keychain access to each build's code hash.
if [[ ${SIGN:-} == adhoc ]]; then
  IDENTITY=-
else
  IDENTITIES=$(security find-identity -v -p codesigning)
  IDENTITY=$(print -r -- "$IDENTITIES" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
  [[ -z $IDENTITY ]] && print -r -- "$IDENTITIES" | grep -q '"mac-wallpaper development"' && IDENTITY="mac-wallpaper development"
fi
if [[ -n $IDENTITY ]]; then
  codesign --force --sign "$IDENTITY" $APP
  # wecli reads the same Steam login, so it needs the same team signature (and a fixed identifier).
  codesign --force --sign "$IDENTITY" --identifier dev.macwallpaper.wecli $BIN/wecli
else
  codesign --force --sign - $APP >/dev/null 2>&1 || true
fi
echo "built $BIN/wecli and $APP"
