#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/Build/WandelBar.app}"

if [ ! -d "$APP_PATH" ]; then
    echo "Application bundle not found: $APP_PATH" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ARCHITECTURE="$(file "$APP_PATH/Contents/MacOS/WandelBar")"
if [[ "$ARCHITECTURE" == *"arm64"* && "$ARCHITECTURE" != *"x86_64"* ]]; then
    ARCH_LABEL="arm64"
elif [[ "$ARCHITECTURE" == *"arm64"* && "$ARCHITECTURE" == *"x86_64"* ]]; then
    ARCH_LABEL="universal"
else
    ARCH_LABEL="x86_64"
fi

OUTPUT_PATH="${2:-$ROOT_DIR/Build/WandelBar-$VERSION-macOS-$ARCH_LABEL.dmg}"
BACKGROUND_SOURCE="$ROOT_DIR/Resources/DMG/dmg-background.jpeg"

if [ ! -f "$BACKGROUND_SOURCE" ]; then
    echo "DMG background not found: $BACKGROUND_SOURCE" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
STAGING_DIR="$WORK_DIR/staging"
RW_DMG="$WORK_DIR/WandelBar-rw.dmg"
MOUNT_DIR=""
DEVICE=""

cleanup() {
    if [ -n "$DEVICE" ]; then
        hdiutil detach "$DEVICE" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGING_DIR/.background" "$(dirname "$OUTPUT_PATH")"
ditto "$APP_PATH" "$STAGING_DIR/WandelBar.app"
ln -s /Applications "$STAGING_DIR/Applications"
sips \
    --resampleHeightWidth 760 1200 \
    --setProperty dpiWidth 144 \
    --setProperty dpiHeight 144 \
    --setProperty format jpeg \
    --setProperty formatOptions 95 \
    "$BACKGROUND_SOURCE" \
    --out "$STAGING_DIR/.background/dmg-background.jpeg" >/dev/null

hdiutil create \
    -volname "WandelBar" \
    -srcfolder "$STAGING_DIR" \
    -format UDRW \
    -ov \
    "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
DEVICE="$(print -r -- "$ATTACH_OUTPUT" | awk '/\/Volumes\// { print $1; exit }')"
MOUNT_DIR="$(print -r -- "$ATTACH_OUTPUT" | awk 'match($0, /\/Volumes\/.*/) { print substr($0, RSTART); exit }')"
if [ -z "$DEVICE" ] || [ -z "$MOUNT_DIR" ]; then
    echo "Could not identify the mounted DMG device or volume" >&2
    exit 1
fi
MOUNT_NAME="${MOUNT_DIR:t}"

SetFile -a V "$MOUNT_DIR/.background"

osascript - "$MOUNT_NAME" >/dev/null <<'APPLESCRIPT'
on run arguments
set volumeName to item 1 of arguments
tell application "Finder"
    tell disk volumeName
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set bounds of container window to {120, 120, 720, 568}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 13
        set background picture of theViewOptions to file ".background:dmg-background.jpeg"
        set position of item "WandelBar.app" of container window to {155, 180}
        set position of item "Applications" of container window to {445, 180}
        update without registering applications
        delay 2
        close
    end tell
end tell
end run
APPLESCRIPT

sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$OUTPUT_PATH" >/dev/null

echo "$OUTPUT_PATH"
