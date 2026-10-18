#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Build a fresh bundle without replacing a running development app.
mkdir -p .tmp/release build/releases
STAGING=$(mktemp -d .tmp/release/package.XXXXXX)
WINK_BUILD_DIR="$STAGING" bash scripts/build.sh
APP="$STAGING/Wink.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(lipo -archs "$APP/Contents/MacOS/Wink")
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "Unexpected binary architecture: $ARCH" >&2; exit 1 ;;
esac
OUTPUT="build/releases/Wink-$VERSION-macos-$ARCH.zip"
if [[ -e "$OUTPUT" || -e "$OUTPUT.sha256" ]]; then
    echo "Release already exists; refusing to overwrite: $OUTPUT" >&2
    exit 1
fi
codesign --verify --deep --strict "$APP"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUTPUT"
(cd build/releases && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
printf 'Packaged: %s\n' "$OUTPUT"
