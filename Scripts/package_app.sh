#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/Build/WandelBar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

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
mkdir -p "$RESOURCES_DIR/Preview"
cp "Sources/WandelBar/Resources/Preview/PresetSampleBackground.png" "$RESOURCES_DIR/Preview/PresetSampleBackground.png"
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
    codesign --force --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
