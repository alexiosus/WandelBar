#!/bin/zsh
set -euo pipefail
set +x
umask 077
: "${RUNNER_TEMP:?Only run on the release runner}"
: "${DEVELOPER_ID_P12_BASE64:?Missing signing identity}"
: "${DEVELOPER_ID_P12_PASSWORD:?Missing export password}"
: "${APPLE_NOTARY_PASSWORD:?Missing notarization password}"
: "${APPLE_ID:?Missing Apple Account}"
: "${APPLE_TEAM_ID:?Missing team}"
: "${WANDELBAR_SIGNING_IDENTITY:?Missing identity name}"
: "${SPARKLE_PRIVATE_KEY:?Missing update signing key}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
SIGNING_DIR="$(mktemp -d "$RUNNER_TEMP/wandelbar-signing.XXXXXX")"
KEYCHAIN_PATH="$SIGNING_DIR/release.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
    [[ -n "$keychain" ]] && ORIGINAL_KEYCHAINS+=("$keychain")
done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
cleanup() {
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    rm -rf "$SIGNING_DIR"
}
trap cleanup EXIT
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$SIGNING_DIR/identity.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$SIGNING_DIR/identity.p12" -k "$KEYCHAIN_PATH" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" "${ORIGINAL_KEYCHAINS[@]}"
rm -f "$SIGNING_DIR/identity.p12"
unset DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD
# Suppress credential setup output; notarytool validates before saving.
xcrun notarytool store-credentials release --keychain "$KEYCHAIN_PATH" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_NOTARY_PASSWORD" >/dev/null
unset APPLE_NOTARY_PASSWORD

./Scripts/package_app.sh
APP="$ROOT_DIR/Build/WandelBar.app"
codesign --verify --deep --strict "$APP"
# Require the expected team, a real Developer ID chain and Hardened Runtime.
codesign -dvv "$APP" > "$SIGNING_DIR/signature.txt" 2>&1
grep -F "TeamIdentifier=$APPLE_TEAM_ID" "$SIGNING_DIR/signature.txt" >/dev/null
grep -F 'Authority=Developer ID Application:' "$SIGNING_DIR/signature.txt" >/dev/null
grep -F '(runtime)' "$SIGNING_DIR/signature.txt" >/dev/null
notarize() {
    local input="$1"
    xcrun notarytool submit "$input" --keychain-profile release --keychain "$KEYCHAIN_PATH" \
        --wait --timeout 30m --output-format json > "$SIGNING_DIR/notary-result.json"
    cat "$SIGNING_DIR/notary-result.json"
    if [[ "$(plutil -extract status raw -o - "$SIGNING_DIR/notary-result.json")" != Accepted ]]; then
        echo 'Apple did not accept this artifact. Release stopped.' >&2
        return 1
    fi
}
ditto -c -k --keepParent "$APP" "$SIGNING_DIR/app.zip"
notarize "$SIGNING_DIR/app.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
DMG_PATH="$(./Scripts/create_dmg.sh)"
codesign --force --timestamp --sign "$WANDELBAR_SIGNING_IDENTITY" "$DMG_PATH"
codesign --verify --strict "$DMG_PATH"
notarize "$DMG_PATH"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
hdiutil verify "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
mkdir -p Build/Release
cp "$DMG_PATH" Build/Release/
./Scripts/prepare_updates.sh "$DMG_PATH" "$ROOT_DIR/Build/Release"
unset SPARKLE_PRIVATE_KEY
cd Build/Release
shasum -a 256 "$(basename "$DMG_PATH")" appcast.xml > SHA256SUMS
