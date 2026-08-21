import AppKit
import Foundation
import Testing
@testable import WandelBar

@Test func storedDesktopDecodesLegacyDataWithoutSourceIdentity() throws {
    let data = Data(#"{"urlString":"file:///Pictures/wallpaper.jpg"}"#.utf8)

    let desktop = try JSONDecoder().decode(StoredDesktop.self, from: data)

    #expect(desktop.url?.path == "/Pictures/wallpaper.jpg")
    #expect(desktop.sourceIdentity == nil)
    #expect(desktop.generatedPath == nil)
}

@Test func capturedDesktopPersistsWallpaperIdentity() {
    let identity = WallpaperIdentity.photosAsset("asset-id")
    let desktop = StoredDesktop.capture(
        url: URL(fileURLWithPath: "/tmp/exported.heic"),
        options: DesktopOptionsSnapshot(options: [:]),
        sourceIdentity: identity
    )

    #expect(desktop.sourceIdentity == identity.stableIdentifier)
}
