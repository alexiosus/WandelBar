#!/bin/zsh
# Compile the actual catalogue service into an app with SwiftPM's fallback made unavailable.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_ROOT="$(mktemp -d)"
trap 'rm -rf "$PROBE_ROOT"' EXIT
PROBE_APP="$PROBE_ROOT/ResourceProbe.app"
mkdir -p "$PROBE_APP/Contents/MacOS" "$PROBE_APP/Contents/Resources/Community"
cp "$ROOT_DIR"/Sources/WandelBar/Resources/Community/*.json "$PROBE_APP/Contents/Resources/Community/"
cat > "$PROBE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>ResourceProbe</string><key>CFBundleIdentifier</key><string>local.WandelBar.ResourceProbe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
cat > "$PROBE_ROOT/ResourceAccessor.swift" <<'SWIFT'
import Foundation
// This probe exercises resource loading only; archive validation has separate tests.
enum CommunityPackageAttachment {
    static func unwrap(_ data: Data) throws -> Data { throw URLError(.unsupportedURL) }
}
extension Bundle {
    static var module: Bundle { fatalError("Packaged catalogue accessed unavailable SwiftPM resources") }
}
SWIFT
cat > "$PROBE_ROOT/main.swift" <<'SWIFT'
import Foundation
let configuration = CommunityCatalogConfiguration.bundled()
guard Data(base64Encoded: configuration.publicKey)?.count == 32 else { fatalError("Missing packaged public key") }
Task {
    do {
        let service = CommunityCatalogService(configuration: configuration,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            transport: { _, _ in throw URLError(.notConnectedToInternet) })
        let result = try await service.load()
        guard result.status.contains("bundled"), result.isCached else { fatalError("Missing signed bundled seed") }
        print("Portable community resources and pinned seed verified without SwiftPM bundle")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Portable resource check failed: \(error)\n".utf8))
        exit(1)
    }
}
dispatchMain()
SWIFT
swiftc -swift-version 6 "$ROOT_DIR/Sources/WandelBar/CommunityCatalog.swift" "$PROBE_ROOT/ResourceAccessor.swift" "$PROBE_ROOT/main.swift" -o "$PROBE_APP/Contents/MacOS/ResourceProbe"
"$PROBE_APP/Contents/MacOS/ResourceProbe"
