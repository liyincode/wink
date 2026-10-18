#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Compile production AppKit controls into an isolated regression executable.
# This does not launch Wink, change Gamma, or save application preferences.
swift build --build-system native
BIN=$(swift build --build-system native --show-bin-path)
OUTPUT="$PWD/.tmp/ui-check"
mkdir -p "$OUTPUT"
SOURCES=()
for source in Sources/Wink/*.swift; do
    [[ "$source" == Sources/Wink/main.swift ]] || SOURCES+=("$source")
done
swiftc -I "$BIN/Modules" Tests/WinkUI/main.swift "${SOURCES[@]}" \
    "$BIN/Wink.build/DerivedSources/resource_bundle_accessor.swift" \
    "$BIN/ScreenCore.build/"*.swift.o -o "$OUTPUT/check"
for language in en zh-Hans; do
    "$OUTPUT/check" -AppleLanguages "($language)"
done
