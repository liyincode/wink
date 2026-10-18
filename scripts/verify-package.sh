#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGES=(build/releases/Wink-*-macos-arm64.zip)
if [[ ${#PACKAGES[@]} -ne 1 || ! -f "${PACKAGES[0]}" ]]; then
    echo "Expected exactly one Apple Silicon package." >&2
    exit 1
fi
PACKAGE="${PACKAGES[0]}"
(cd build/releases && shasum -a 256 -c "$(basename "$PACKAGE").sha256")
mkdir -p .tmp/release
UNPACKED=$(mktemp -d .tmp/release/verify.XXXXXX)
unzip -q "$PACKAGE" -d "$UNPACKED"
APP="$UNPACKED/Wink.app"
codesign --verify --deep --strict "$APP"
[[ "$(lipo -archs "$APP/Contents/MacOS/Wink")" == arm64 ]]
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$(basename "$PACKAGE")" == "Wink-$VERSION-macos-arm64.zip" ]]
if [[ -n "${RELEASE_TAG:-}" ]]; then
    [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a stable vX.Y.Z tag." >&2; exit 1; }
    [[ "$RELEASE_TAG" == "v$VERSION" ]] || { echo "Tag and app version differ." >&2; exit 1; }
    [[ -s "docs/releases/$RELEASE_TAG.md" ]] || { echo "Release notes are missing." >&2; exit 1; }
fi
for resource in LICENSE mascot-body.png mascot-wink.png Wink.icns \
    Wink_ScreenCore.bundle/en.lproj/Localizable.strings \
    Wink_ScreenCore.bundle/zh-Hans.lproj/Localizable.strings; do
    [[ -s "$APP/Contents/Resources/$resource" ]]
done
"$APP/Contents/MacOS/Wink" --help
printf 'Verified: %s\n' "$PACKAGE"
