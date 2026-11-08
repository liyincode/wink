#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${WINK_SIGNING_IDENTITY:?Set WINK_SIGNING_IDENTITY to your Developer ID Application identity}"
PROFILE="${WINK_NOTARY_PROFILE:-wink-notary}"
# Validate access before building. Credentials remain in the user's Keychain.
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null

mkdir -p .tmp/notarization build/notarized
STAGING=$(mktemp -d .tmp/notarization/package.XXXXXX)
WINK_BUILD_DIR="$STAGING" bash scripts/build.sh
APP="$STAGING/Wink.app"
codesign -d --verbose=4 "$APP" 2> "$STAGING/signature.txt"
grep -q '^Authority=Developer ID Application:' "$STAGING/signature.txt"
grep -q 'flags=.*runtime' "$STAGING/signature.txt"
grep -q '^Timestamp=' "$STAGING/signature.txt"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH=$(lipo -archs "$APP/Contents/MacOS/Wink")
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "Unexpected binary architecture: $ARCH" >&2; exit 1 ;;
esac
NAME="Wink-$VERSION-macos-$ARCH.zip"
OUTPUT="build/notarized/$NAME"
if [[ -e "$OUTPUT" || -e "$OUTPUT.sha256" ]]; then
    echo "Package already exists; refusing to overwrite: $OUTPUT" >&2
    exit 1
fi

COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP" "$STAGING/submission.zip"
echo "Notarization evidence and submission ID: $STAGING"
xcrun notarytool submit "$STAGING/submission.zip" --keychain-profile "$PROFILE" \
    --wait --output-format json > "$STAGING/submission.json"
STATUS=$(/usr/bin/plutil -extract status raw -o - "$STAGING/submission.json")
if [[ "$STATUS" != Accepted ]]; then
    cat "$STAGING/submission.json"
    echo "Notarization was not accepted. No distribution package was produced." >&2
    exit 1
fi

# ZIP files cannot carry stapled tickets. Staple the app, then create a new ZIP.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$APP" "$STAGING/$NAME"

# Verify the exact archive users will extract before moving it into delivery.
mkdir "$STAGING/unpacked"
ditto -x -k "$STAGING/$NAME" "$STAGING/unpacked"
VERIFIED_APP="$STAGING/unpacked/Wink.app"
codesign --verify --deep --strict "$VERIFIED_APP"
xcrun stapler validate "$VERIFIED_APP"
spctl --assess --type execute --verbose=2 "$VERIFIED_APP"
"$VERIFIED_APP/Contents/MacOS/Wink" --help
mv -n "$STAGING/$NAME" "$OUTPUT"
(cd build/notarized && shasum -a 256 "$NAME" > "$NAME.sha256")
printf 'Notarized and verified: %s\n' "$OUTPUT"
