#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native -c release
BUILD_DIR="${WINK_BUILD_DIR:-build}"
APP="$BUILD_DIR/Wink.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Wink "$APP/Contents/MacOS/Wink"
mkdir -p "$APP/Contents/Resources" "$BUILD_DIR/Wink.iconset"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp Sources/Wink/Resources/*.png "$APP/Contents/Resources/"
ditto .build/release/Wink_ScreenCore.bundle "$APP/Contents/Resources/Wink_ScreenCore.bundle"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Sources/Wink/Resources/mascot-wink.png --out "$BUILD_DIR/Wink.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Sources/Wink/Resources/mascot-wink.png --out "$BUILD_DIR/Wink.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD_DIR/Wink.iconset" -o "$APP/Contents/Resources/Wink.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Wink</string>
<key>CFBundleIdentifier</key><string>local.liyin.screenpause</string>
<key>CFBundleName</key><string>Wink</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleAllowMixedLocalizations</key><true/>
<key>CFBundleIconFile</key><string>Wink.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built: %s/%s\n' "$PWD" "$APP"
