import Foundation
import Testing
@testable import WandelBar

@Test func staleOriginalPruningPreservesReferencedFiles() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let referenced = directory.appendingPathComponent("referenced.heic")
    let orphaned = directory.appendingPathComponent("orphaned.heic")
    let recent = directory.appendingPathComponent("recent.heic")
    for file in [referenced, orphaned, recent] {
        try Data("image".utf8).write(to: file)
    }

    let now = Date()
    let oldDate = now.addingTimeInterval(-30 * 24 * 60 * 60)
    try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: referenced.path)
    try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: orphaned.path)

    OriginalCachePruner(fileManager: fileManager).prune(
        directories: [directory],
        preserving: [referenced],
        olderThan: now.addingTimeInterval(-14 * 24 * 60 * 60)
    )

    #expect(fileManager.fileExists(atPath: referenced.path))
    #expect(!fileManager.fileExists(atPath: orphaned.path))
    #expect(fileManager.fileExists(atPath: recent.path))
}

@Test func missingWallpaperIsNotConsideredDirectlyReadable() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let existing = directory.appendingPathComponent("wallpaper.heic")
    let missing = directory.appendingPathComponent("missing.heic")
    try Data("image".utf8).write(to: existing)

    #expect(WallpaperFileValidator.isReadableRegularFile(existing, fileManager: fileManager))
    #expect(!WallpaperFileValidator.isReadableRegularFile(missing, fileManager: fileManager))
    #expect(!WallpaperFileValidator.isReadableRegularFile(directory, fileManager: fileManager))
}

@Test func legacyPhotosCacheURLRecoversItsAssetIdentifier() {
    let cacheDirectory = URL(fileURLWithPath: "/tmp/WandelBar/Originals/Photos", isDirectory: true)
    let identifier = "8583E207-2FE2-437B-8D94-9A1082446039"
    let legacyURL = cacheDirectory.appendingPathComponent(identifier).appendingPathExtension("heic")
    let hashedURL = cacheDirectory
        .appendingPathComponent(String(repeating: "a", count: 64))
        .appendingPathExtension("heic")
    let unrelatedURL = URL(fileURLWithPath: "/tmp/elsewhere/\(identifier).heic")

    #expect(
        WallpaperStoreResolver.legacyPhotosAssetIdentifier(
            in: legacyURL,
            photosCacheDirectory: cacheDirectory
        ) == identifier
    )
    #expect(
        WallpaperStoreResolver.legacyPhotosAssetIdentifier(
            in: hashedURL,
            photosCacheDirectory: cacheDirectory
        ) == nil
    )
    #expect(
        WallpaperStoreResolver.legacyPhotosAssetIdentifier(
            in: unrelatedURL,
            photosCacheDirectory: cacheDirectory
        ) == nil
    )
}

@Test func generatedWallpaperContainmentRejectsDirectoryAndSiblingPrefixes() {
    let directory = URL(fileURLWithPath: "/tmp/WandelBar/Generated", isDirectory: true)
    let child = directory.appendingPathComponent("wallpaper.jpg")
    let siblingPrefix = URL(fileURLWithPath: "/tmp/WandelBar/Generated-Backup/wallpaper.jpg")
    let escaped = directory.appendingPathComponent("../outside.jpg").standardizedFileURL

    #expect(GeneratedWallpaperPaths.contains(child, in: directory))
    #expect(!GeneratedWallpaperPaths.contains(directory, in: directory))
    #expect(!GeneratedWallpaperPaths.contains(siblingPrefix, in: directory))
    #expect(!GeneratedWallpaperPaths.contains(escaped, in: directory))
}

@Test func staleRenderIsRejectedWhenPublicWorkspaceShowsANewWallpaper() {
    let generatedDirectory = URL(fileURLWithPath: "/tmp/WandelBar/Generated", isDirectory: true)
    let original = WallpaperIdentity.file(URL(fileURLWithPath: "/Pictures/original.jpg"))
    let replacement = URL(fileURLWithPath: "/Pictures/replacement.jpg")

    #expect(!WallpaperCurrentness.isCurrent(
        expected: original,
        storeIdentity: nil,
        workspaceURL: replacement,
        generatedDirectory: generatedDirectory
    ))
}

@Test func currentGeneratedWallpaperAllowsASettingsReapplyWhenStoreIsUnavailable() {
    let generatedDirectory = URL(fileURLWithPath: "/tmp/WandelBar/Generated", isDirectory: true)
    let generated = generatedDirectory.appendingPathComponent("current.jpg")

    #expect(WallpaperCurrentness.isCurrent(
        expected: .photosAsset("asset-a"),
        storeIdentity: nil,
        workspaceURL: generated,
        generatedDirectory: generatedDirectory
    ))
}

@Test func changedPhotosAssetTriggersRefreshWithoutExportingIt() {
    let generatedDirectory = URL(fileURLWithPath: "/tmp/WandelBar/Generated", isDirectory: true)
    let generated = generatedDirectory.appendingPathComponent("current.jpg")

    #expect(WallpaperRefreshPolicy.shouldRefresh(
        workspaceURL: generated,
        storeIdentity: .photosAsset("asset-b"),
        savedSourceIdentity: WallpaperIdentity.photosAsset("asset-a").stableIdentifier,
        savedURL: URL(fileURLWithPath: "/tmp/WandelBar/Originals/Photos/cached.heic"),
        generatedDirectory: generatedDirectory
    ))
}

@Test func wallpaperIdentityRoundTripsThroughPersistence() {
    let identities: [WallpaperIdentity] = [
        .file(URL(fileURLWithPath: "/Pictures/wallpaper image.jpg")),
        .photosAsset("8583E207-2FE2-437B-8D94-9A1082446039/L0/001")
    ]

    for identity in identities {
        #expect(WallpaperIdentity(stableIdentifier: identity.stableIdentifier) == identity)
    }
}

@Test func newSpaceRecoversOriginalFromTheVisibleGeneratedWallpaper() {
    let generatedURL = URL(fileURLWithPath: "/tmp/WandelBar/Generated/space-two.jpg")
    var spaceTwo = StoredDesktop.capture(
        url: URL(fileURLWithPath: "/Pictures/current-space-original.jpg"),
        options: DesktopOptionsSnapshot(options: [:]),
        sourceIdentity: .file(URL(fileURLWithPath: "/Pictures/current-space-original.jpg"))
    )
    spaceTwo.generatedPath = generatedURL.path

    var otherDisplay = StoredDesktop.capture(
        url: URL(fileURLWithPath: "/Pictures/other-display.jpg"),
        options: DesktopOptionsSnapshot(options: [:])
    )
    otherDisplay.generatedPath = generatedURL.path

    let recovered = GeneratedWallpaperRecovery.storedDesktop(
        matching: generatedURL,
        displayIDs: ["display", "legacy-display"],
        in: [
            "display::space-two": spaceTwo,
            "other-display::space-two": otherDisplay
        ]
    )

    #expect(recovered?.url?.path == "/Pictures/current-space-original.jpg")
}

@Test func turningOffKeepsAVideoWallpaperTheUserPickedLater() {
    // WandelBar's generated wallpaper is gone: the user switched to a video wallpaper
    // while it was on. Restoring the stored still would overwrite that choice.
    #expect(
        WallpaperRestorePolicy.shouldAbandonStoredOriginal(
            currentIsGenerated: false,
            unsupportedReason: "video wallpapers are not supported"
        )
    )
}

@Test func turningOffStillRestoresWhenWandelBarsWallpaperIsOnScreen() {
    #expect(
        !WallpaperRestorePolicy.shouldAbandonStoredOriginal(
            currentIsGenerated: true,
            unsupportedReason: "video wallpapers are not supported"
        )
    )
    #expect(
        !WallpaperRestorePolicy.shouldAbandonStoredOriginal(
            currentIsGenerated: false,
            unsupportedReason: nil
        )
    )
}
