#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/Build/WandelBar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Prefer an installed Developer ID for local builds. CI without a certificate
# can still package an ad-hoc test build; ambiguous identities require a choice.
SIGNING_IDENTITY="${WANDELBAR_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    DEVELOPER_IDENTITIES=()
    while IFS= read -r identity; do
        [[ -n "$identity" ]] && DEVELOPER_IDENTITIES+=("$identity")
    done < <(security find-identity -v -p codesigning | awk -F '"' '/"Developer ID Application: / {print $2}')
    if (( ${#DEVELOPER_IDENTITIES[@]} == 1 )); then
        SIGNING_IDENTITY="$DEVELOPER_IDENTITIES[1]"
    elif (( ${#DEVELOPER_IDENTITIES[@]} > 1 )); then
        echo "Multiple Developer ID identities found; set WANDELBAR_SIGNING_IDENTITY explicitly." >&2
        exit 1
    fi
fi
if [[ -n "$SIGNING_IDENTITY" ]]; then
    if [[ "$SIGNING_IDENTITY" != 'Developer ID Application: '* ]]; then
        echo "WANDELBAR_SIGNING_IDENTITY must be a Developer ID Application certificate name." >&2
        exit 1
    fi
    if ! security find-identity -v -p codesigning | /usr/bin/grep -F -- "\"$SIGNING_IDENTITY\"" >/dev/null; then
        echo "The requested signing identity is unavailable in Keychain." >&2
        exit 1
    fi
fi

cd "$ROOT_DIR"

swift build -c release --product WandelBar

# Packaging must be reproducible: do not leave resources from an older bundle behind.
if [ -e "$APP_DIR" ]; then
    rm -rf "$APP_DIR"
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build/release/WandelBar" "$MACOS_DIR/WandelBar"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "LICENSE" "$RESOURCES_DIR/LICENSE.txt"
cp "Resources/THIRD_PARTY_NOTICES.txt" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.txt"
SPARKLE_ROOT="$ROOT_DIR/.build/artifacts/sparkle/Sparkle"
mkdir -p "$CONTENTS_DIR/Frameworks"
ditto "$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
    "$CONTENTS_DIR/Frameworks/Sparkle.framework"
printf '\n\nSparkle software update framework\n\n' >> "$RESOURCES_DIR/THIRD_PARTY_NOTICES.txt"
cat "$SPARKLE_ROOT/LICENSE" >> "$RESOURCES_DIR/THIRD_PARTY_NOTICES.txt"
mkdir -p "$RESOURCES_DIR/Community"
cp Sources/WandelBar/Resources/Community/*.json "$RESOURCES_DIR/Community/"
mkdir -p "$RESOURCES_DIR/Preview"
cp "Sources/WandelBar/Resources/Preview/PresetSampleBackground.png" "$RESOURCES_DIR/Preview/PresetSampleBackground.png"
cp "Sources/WandelBar/Resources/Preview/PresetSampleSource.png" "$RESOURCES_DIR/Preview/PresetSampleSource.png"
mkdir -p "$RESOURCES_DIR/Textures"
cp "Sources/WandelBar/Resources/Textures/AzureReflection.png" "$RESOURCES_DIR/Textures/AzureReflection.png"
cp "Sources/WandelBar/Resources/Textures/OceanBlue.png" "$RESOURCES_DIR/Textures/OceanBlue.png"
cp "Sources/WandelBar/Resources/Textures/ClassicBlue.png" "$RESOURCES_DIR/Textures/ClassicBlue.png"
cp "Sources/WandelBar/Resources/Textures/ClassicOlive.png" "$RESOURCES_DIR/Textures/ClassicOlive.png"
cp "Sources/WandelBar/Resources/Textures/EmbeddedSlate.png" "$RESOURCES_DIR/Textures/EmbeddedSlate.png"
cp "Sources/WandelBar/Resources/Textures/RoyalNoir.png" "$RESOURCES_DIR/Textures/RoyalNoir.png"
cp "Sources/WandelBar/Resources/Textures/StripedLight.png" "$RESOURCES_DIR/Textures/StripedLight.png"
cp "Sources/WandelBar/Resources/Textures/StripedDark.png" "$RESOURCES_DIR/Textures/StripedDark.png"
cp "Sources/WandelBar/Resources/Textures/SilverGlass.png" "$RESOURCES_DIR/Textures/SilverGlass.png"
cp "Sources/WandelBar/Resources/Textures/GraphiteGlass.png" "$RESOURCES_DIR/Textures/GraphiteGlass.png"
cp "Sources/WandelBar/Resources/Textures/CoastalLight.png" "$RESOURCES_DIR/Textures/CoastalLight.png"
cp "Sources/WandelBar/Resources/Textures/CoastalDark.png" "$RESOURCES_DIR/Textures/CoastalDark.png"
chmod +x "$MACOS_DIR/WandelBar"

# Compile the native macOS 26 icon. Its single artwork layer is full-bleed so
# the system mask does not place a finished rounded icon inside another icon.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if command -v xcrun >/dev/null 2>&1 \
    && [ -d "Resources/AppIcon.icon" ] \
    && [[ "$SDK_MAJOR" == <-> ]] \
    && (( SDK_MAJOR >= 26 )); then
    ICON_BUILD="$(mktemp -d)"
    xcrun actool "Resources/AppIcon.icon" \
        --compile "$ICON_BUILD" \
        --app-icon AppIcon \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --output-partial-info-plist "$ICON_BUILD/partial.plist" \
        --errors --warnings >/dev/null
    cp "$ICON_BUILD/Assets.car" "$RESOURCES_DIR/Assets.car"
    rm -rf "$ICON_BUILD"
fi

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

if command -v codesign >/dev/null 2>&1; then
    # Sign inside out, preserving the XPC helpers' required entitlements.
    # --deep is for verification only, never a replacement for explicit signing.
    SPARKLE_FRAMEWORK="$CONTENTS_DIR/Frameworks/Sparkle.framework"
    SIGN_ARGS=(--force --sign "${SIGNING_IDENTITY:--}" --preserve-metadata=entitlements)
    if [[ -n "$SIGNING_IDENTITY" ]]; then
        SIGN_ARGS+=(--options runtime --timestamp)
    fi
    for component in \
        "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" \
        "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" \
        "$SPARKLE_FRAMEWORK"; do
        codesign "${SIGN_ARGS[@]}" "$component"
    done
    if [[ -n "$SIGNING_IDENTITY" ]]; then
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR"
    else
        codesign --force --sign - "$APP_DIR" >/dev/null
    fi
    codesign --verify --deep --strict "$APP_DIR"
fi

echo "$APP_DIR"
