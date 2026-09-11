#!/bin/zsh
# Run after the final DMG has been signed, notarized and stapled.
set -euo pipefail
set +x
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
DMG="${1:?Pass the final notarized DMG}"
OUTPUT="${2:-$ROOT_DIR/Build/Release}"
PLIST="$ROOT_DIR/Build/WandelBar.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
[[ "$(basename "$DMG")" == "WandelBar-$VERSION-macOS-arm64.dmg" ]]
TOOLS="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$DMG" "$WORK/"
# Markdown release notes are embedded in the signed feed, with no external HTML.
python3 Scripts/release_notes.py "$VERSION" CHANGELOG.md > "$WORK/$(basename "$DMG" .dmg).md"
ARGS=(--download-url-prefix "https://github.com/alexiosus/WandelBar/releases/download/v$VERSION/"
      --link https://github.com/alexiosus/WandelBar --maximum-deltas 0
      --embed-release-notes -o "$WORK/appcast.xml" "$WORK")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/generate_appcast" --ed-key-file - "${ARGS[@]}"
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/sign_update" --verify --ed-key-file - "$WORK/appcast.xml"
else
    "$TOOLS/generate_appcast" --account com.alexeremeev.WandelBar "${ARGS[@]}"
    "$TOOLS/sign_update" --verify --account com.alexeremeev.WandelBar "$WORK/appcast.xml"
fi
# Reject archives signed with an accidentally different CI key before publishing.
swift Scripts/verify_update.swift "$PLIST" "$WORK/appcast.xml" "$DMG"
mkdir -p "$OUTPUT"
cp "$WORK/appcast.xml" "$OUTPUT/appcast.xml"
