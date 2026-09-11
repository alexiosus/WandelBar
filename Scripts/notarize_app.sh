#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/Build/WandelBar.app"
PROFILE="${WANDELBAR_NOTARY_PROFILE:?Set WANDELBAR_NOTARY_PROFILE to your notarytool Keychain profile name}"
: "${WANDELBAR_SIGNING_IDENTITY:?Set WANDELBAR_SIGNING_IDENTITY to your Developer ID Application certificate name}"

"$ROOT_DIR/Scripts/package_app.sh"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$STAGING_DIR/WandelBar.zip"
xcrun notarytool submit "$STAGING_DIR/WandelBar.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$STAGING_DIR/result.json"
cat "$STAGING_DIR/result.json"
if [[ "$(plutil -extract status raw -o - "$STAGING_DIR/result.json")" != Accepted ]]; then
    echo "Notarization was not accepted; no distribution archive was produced." >&2
    exit 1
fi
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
spctl --assess --type execute --verbose=2 "$APP_DIR"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$STAGING_DIR/WandelBar-notarized.zip"
mv -f "$STAGING_DIR/WandelBar-notarized.zip" "$ROOT_DIR/Build/WandelBar-notarized.zip"
echo "$ROOT_DIR/Build/WandelBar-notarized.zip"
