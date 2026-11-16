#!/bin/zsh
# Build "Let It Snow.app" into ./build
#   zsh build.sh            build only
#   zsh build.sh --run      build, then launch
#   zsh build.sh --install  build, then copy to ~/Applications and launch from there
#   zsh build.sh --zip      build, then zip the app for a release (build/LetItSnow-<version>.zip)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Let It Snow"
EXE="LetItSnow"
APP="build/$APP_NAME.app"
MIN_OS="13.0"

# Quit a running copy so the new build can replace it
pkill -x "$EXE" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary (Apple silicon + Intel)
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos$MIN_OS" Sources/*.swift -o "build/$EXE-$arch"
done
lipo -create "build/$EXE-arm64" "build/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"
rm -f "build/$EXE-arm64" "build/$EXE-x86_64"

cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc signature so macOS will run it locally
xattr -cr "$APP"
codesign --force --sign - "$APP"

echo "Built $APP ❄︎"

case "${1:-}" in
  --run)
    open "$APP" ;;
  --install)
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$APP_NAME.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/$APP_NAME.app"
    echo "Installed to ~/Applications/$APP_NAME.app" ;;
  --zip)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    ZIP="build/$EXE-$VERSION.zip"
    rm -f "$ZIP"
    # ditto keeps the bundle structure and code signature intact
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Packaged $ZIP" ;;
esac
