import Foundation
import Testing
@testable import WandelBar

@Test @MainActor func sharingBundleContainsOnlyPreparedPackageAndSamplePreviews() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let presets = EffectPresetStore(defaults: fixture.defaults, storageKey: "share-presets")
    let preset = try presets.createUserPreset(name: "Shared Glass", settings: .default)
    let packages = PresetPackageService(presetStore: presets, textureStore: fixture.store)
    let service = PresetSharingService(packages: packages, textures: fixture.store)
    let result = try await service.prepare(presets: [preset], in: fixture.directory)
    #expect(result.previewURLs.count == 1)
    let files = Set(try FileManager.default.contentsOfDirectory(atPath: result.directory.path))
    #expect(files == ["Presets.zip", "Preview-1.png", "Post.md"])
    #expect(try Data(contentsOf: result.previewURLs[0]).count > 100)
    let zip = try Data(contentsOf: result.directory.appendingPathComponent("Presets.zip"))
    #expect(zip.starts(with: [0x50, 0x4b]))
    #expect(result.markdown.contains("Shared Glass"))
}

@Test @MainActor func currentWallpaperChangesOnlyPreviewAndIsNotRetainedInShareFiles() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let presets = EffectPresetStore(defaults: fixture.defaults, storageKey: "wallpaper-share")
    let preset = try presets.createUserPreset(name: "Current Wallpaper", settings: .default)
    let packages = PresetPackageService(presetStore: presets, textureStore: fixture.store)
    let service = PresetSharingService(packages: packages, textures: fixture.store)
    let source = try #require(PresetSampleBackground.renderURL)
    let display = DisplaySnapshot(id: "private-display", localizedName: "Private display name",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900), backingScaleFactor: 2, statusBarThickness: 24)
    let context = PresetPreviewContext(sourceURL: source, display: display,
        storedDesktop: StoredDesktop(urlString: source.absoluteString, imageScaling: nil, allowClipping: true, fillColorData: nil),
        sourceIdentity: "private-wallpaper-id")
    let sample = try await service.prepare(presets: [preset], in: fixture.directory)
    let current = try await service.prepare(presets: [preset], in: fixture.directory, wallpaper: context)
    #expect(current.usesCurrentWallpaper)
    #expect(current.markdown.contains("my current wallpaper"))
    #expect(!current.markdown.contains("standard sample background"))
    #expect(!current.markdown.contains(source.path))
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: current.directory.path)) == ["Presets.zip", "Preview-1.png", "Post.md"])
    #expect(try Data(contentsOf: current.directory.appendingPathComponent("Presets.zip")) == Data(contentsOf: sample.directory.appendingPathComponent("Presets.zip")))
    #expect(try Data(contentsOf: current.previewURLs[0]) != Data(contentsOf: sample.previewURLs[0]))
    let permissions = try FileManager.default.attributesOfItem(atPath: current.directory.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
}
