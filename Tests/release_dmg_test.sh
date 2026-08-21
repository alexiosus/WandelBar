#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/Build/WandelBar.app"
TEST_DIR="$(mktemp -d)"
DMG_PATH="$TEST_DIR/WandelBar-Test.dmg"
MOUNT_PATH=""
DEVICE=""

cleanup() {
    if [ -n "$DEVICE" ]; then
        hdiutil detach "$DEVICE" -quiet || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

if [ ! -d "$APP_PATH" ]; then
    "$ROOT_DIR/Scripts/package_app.sh"
fi

CREATE_OUTPUT="$("$ROOT_DIR/Scripts/create_dmg.sh" "$APP_PATH" "$DMG_PATH")"

test -f "$DMG_PATH"
test "$CREATE_OUTPUT" = "$DMG_PATH"
hdiutil verify "$DMG_PATH" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$DMG_PATH" -nobrowse -readonly)"
DEVICE="$(print -r -- "$ATTACH_OUTPUT" | awk '/\/Volumes\// { print $1; exit }')"
MOUNT_PATH="$(print -r -- "$ATTACH_OUTPUT" | awk 'match($0, /\/Volumes\/.*/) { print substr($0, RSTART); exit }')"

test -n "$DEVICE"
test -n "$MOUNT_PATH"

test -d "$MOUNT_PATH/WandelBar.app"
test -L "$MOUNT_PATH/Applications"
test -f "$MOUNT_PATH/.background/dmg-background.jpeg"
test -f "$MOUNT_PATH/.DS_Store"
test -f "$MOUNT_PATH/WandelBar.app/Contents/Resources/LICENSE.txt"
cmp "$ROOT_DIR/LICENSE" "$MOUNT_PATH/WandelBar.app/Contents/Resources/LICENSE.txt"
codesign --verify --deep --strict "$MOUNT_PATH/WandelBar.app"

BACKGROUND_METADATA="$(sips \
    -g pixelWidth \
    -g pixelHeight \
    -g dpiWidth \
    -g dpiHeight \
    "$MOUNT_PATH/.background/dmg-background.jpeg")"
test "$(print -r -- "$BACKGROUND_METADATA" | awk '/pixelWidth:/ { print $2 }')" = "1200"
test "$(print -r -- "$BACKGROUND_METADATA" | awk '/pixelHeight:/ { print $2 }')" = "760"
test "$(print -r -- "$BACKGROUND_METADATA" | awk '/dpiWidth:/ { printf "%.0f", $2 }')" = "144"
test "$(print -r -- "$BACKGROUND_METADATA" | awk '/dpiHeight:/ { printf "%.0f", $2 }')" = "144"

MOUNT_NAME="${MOUNT_PATH:t}"
WINDOW_BOUNDS="$(osascript - "$MOUNT_NAME" <<'APPLESCRIPT'
on run arguments
set volumeName to item 1 of arguments
tell application "Finder"
    tell disk volumeName
        open
        delay 1
        set windowBounds to bounds of container window
        close
        return windowBounds
    end tell
end tell
end run
APPLESCRIPT
)"
WINDOW_HEIGHT="$(print -r -- "$WINDOW_BOUNDS" | awk -F', ' '{ print $4 - $2 }')"
if [ "$WINDOW_HEIGHT" -ne 448 ]; then
    echo "Expected a 448 pt Finder window without an uncovered bottom strip; got $WINDOW_HEIGHT pt" >&2
    exit 1
fi

echo "DMG artifact contract passed"
