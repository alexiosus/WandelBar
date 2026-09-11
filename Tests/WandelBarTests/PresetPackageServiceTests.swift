import Foundation
import Testing
import UniformTypeIdentifiers
@testable import WandelBar

@MainActor
private final class PresetPackageFixture {
    let textures: TextureStoreFixture
    let defaults: UserDefaults
    let suiteName: String
    let presets: EffectPresetStore
    let service: PresetPackageService
    let packageURL: URL

    init() throws {
        textures = try TextureStoreFixture()
        suiteName = "WandelBarTests.PresetPackage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        presets = EffectPresetStore(defaults: defaults, storageKey: "presets")
        service = PresetPackageService(
            presetStore: presets,
            textureStore: textures.store,
            archive: SystemPresetPackageArchive()
        )
        packageURL = textures.directory.appendingPathComponent("Shared.wandelbar-presets")
    }

    func createPreset(
        name: String,
        textureID: String? = nil,
        blur: Double = WallpaperEffectSettings.default.blurRadiusPoints
    ) throws -> EffectPreset {
        var settings = WallpaperEffectSettings.default
        settings.textureID = textureID
        settings.blurRadiusPoints = blur
        return try presets.createUserPreset(name: name, settings: settings)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        textures.cleanUp()
    }
}

@Test @MainActor func realPresetPackageRoundTripPreservesSettingsAndSharedTexture() async throws {
    let source = try PresetPackageFixture()
    let destination = try PresetPackageFixture()
    defer { source.cleanUp(); destination.cleanUp() }

    let image = try source.textures.makeImage(
        name: "Shared Wave", type: .png, width: 24, height: 12
    )
    let texture = try await source.textures.store.importTexture(from: image)
    let first = try source.createPreset(name: "One", textureID: texture.id, blur: 23)
    let second = try source.createPreset(name: "Two", textureID: texture.id, blur: 17)

    let exported = try await source.service.export(
        presetIDs: [first.id, second.id],
        to: source.packageURL
    )
    #expect(exported == PresetPackageExportSummary(presetCount: 2, textureCount: 1))

    let preview = try await destination.service.prepareImport(from: source.packageURL)
    #expect(preview.presets.map(\.finalName) == ["One", "Two"])
    #expect(preview.embeddedTextureCount == 1)
    let imported = try destination.service.commitImport(preview)
    #expect(imported == PresetPackageImportResult(presetCount: 2, newTextureCount: 1))
    #expect(Set(destination.presets.userPresets.map(\.id)).isDisjoint(with: [first.id, second.id]))
    #expect(Set(destination.presets.userPresets.compactMap { $0.settings.textureID }).count == 1)
    #expect(destination.presets.userPresets.map { $0.settings.blurRadiusPoints } == [23, 17])
    #expect(destination.textures.store.customAssets.count == 1)
    #expect(throws: PresetPackageError.previewExpired) {
        try destination.service.commitImport(preview)
    }
}

@Test @MainActor func importPreviewResolvesEveryPresetNameConflict() async throws {
    let source = try PresetPackageFixture()
    let destination = try PresetPackageFixture()
    defer { source.cleanUp(); destination.cleanUp() }
    _ = try source.createPreset(name: "Ocean")
    _ = try source.createPreset(name: "Night")
    _ = try destination.createPreset(name: "Ocean")
    _ = try destination.createPreset(name: "Ocean (Imported)")

    _ = try await source.service.export(
        presetIDs: source.presets.userPresets.map(\.id),
        to: source.packageURL
    )
    let preview = try await destination.service.prepareImport(from: source.packageURL)
    #expect(preview.presets.map(\.finalName) == ["Night", "Ocean (Imported 2)"])
    #expect(preview.presets.map(\.wasRenamed) == [false, true])
    destination.service.discardImport(preview)
    #expect(throws: PresetPackageError.previewExpired) {
        try destination.service.commitImport(preview)
    }
}

@Test @MainActor func missingCustomTextureAbortsExportWithoutDestination() async throws {
    let fixture = try PresetPackageFixture()
    defer { fixture.cleanUp() }
    let preset = try fixture.createPreset(name: "Broken", textureID: "custom.missing")

    await #expect(throws: PresetPackageError.sourceTextureMissing("custom.missing")) {
        try await fixture.service.export(presetIDs: [preset.id], to: fixture.packageURL)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.packageURL.path))
}

@Test @MainActor func builtInTextureIsReferencedWithoutBeingEmbedded() async throws {
    let fixture = try PresetPackageFixture()
    defer { fixture.cleanUp() }
    let preset = try fixture.createPreset(
        name: "Azure", textureID: TextureAsset.azureReflection.id
    )

    let summary = try await fixture.service.export(
        presetIDs: [preset.id], to: fixture.packageURL
    )
    #expect(summary.textureCount == 0)

    let extraction = fixture.textures.directory.appendingPathComponent("inspect", isDirectory: true)
    try SystemPresetPackageArchive().extractArchive(at: fixture.packageURL, to: extraction)
    let manifest = try JSONDecoder().decode(
        PresetPackageManifest.self,
        from: Data(contentsOf: extraction.appendingPathComponent("manifest.json"))
    )
    #expect(manifest.presets[0].texture?.kind == .builtIn)
    #expect(manifest.presets[0].texture?.id == TextureAsset.azureReflection.id)
    #expect(!FileManager.default.fileExists(atPath: extraction.appendingPathComponent("textures").path))
}

@Test @MainActor func selectedImportInstallsOnlySelectedTextureAndCarriesVisualSettings() async throws {
    let source = try PresetPackageFixture(), destination = try PresetPackageFixture()
    defer { source.cleanUp(); destination.cleanUp() }
    let image = try source.textures.makeImage(name: "Unselected", type: .png, width: 24, height: 12)
    let texture = try await source.textures.store.importTexture(from: image)
    let selected = try source.createPreset(name: "Selected", blur: 27)
    let unselected = try source.createPreset(name: "Unselected", textureID: texture.id)
    _ = try await source.service.export(presetIDs: [selected.id, unselected.id], to: source.packageURL)
    let preview = try await destination.service.prepareImport(from: source.packageURL)
    #expect(preview.presets.first { $0.id == selected.id }?.settings.blurRadiusPoints == 27)
    #expect(preview.presets.first { $0.id == unselected.id }?.previewPNG != nil)
    #expect(preview.presets.first { $0.id == selected.id }?.previewPNG != nil)
    let result = try destination.service.commitImport(preview, selectedIDs: [selected.id])
    #expect(result == PresetPackageImportResult(presetCount: 1, newTextureCount: 0))
    #expect(destination.presets.userPresets.map(\.name) == ["Selected"])
    #expect(destination.textures.store.customAssets.isEmpty)
}

@Test @MainActor func exportAppliesExtractedAndCompressedLimitsWithoutReplacingDestination() async throws {
    let fixture = try PresetPackageFixture()
    defer { fixture.cleanUp() }
    let preset = try fixture.createPreset(name: "Test")
    let original = Data("keep this".utf8)
    try original.write(to: fixture.packageURL)
    for limits in [
        PresetPackageLimits(maximumPresets: 100, maximumTextures: 100, maximumCompressedBytes: 100000, maximumExtractedBytes: 10),
        PresetPackageLimits(maximumPresets: 100, maximumTextures: 100, maximumCompressedBytes: 10, maximumExtractedBytes: 100000)
    ] {
        let service = PresetPackageService(presetStore: fixture.presets, textureStore: fixture.textures.store, limits: limits)
        await #expect(throws: PresetPackageError.limitsExceeded) {
            try await service.export(presetIDs: [preset.id], to: fixture.packageURL)
        }
        #expect(try Data(contentsOf: fixture.packageURL) == original)
    }
}

@Test @MainActor func cancelledExportDoesNotWriteDestination() async throws {
    let fixture = try PresetPackageFixture()
    defer { fixture.cleanUp() }
    let preset = try fixture.createPreset(name: "Cancelled")
    let task = Task { try await fixture.service.export(presetIDs: [preset.id], to: fixture.packageURL) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: fixture.packageURL.path))
}

private struct BackgroundCheckingArchive: PresetPackageArchiving {
    func createArchive(from sourceDirectory: URL, at destinationURL: URL) throws {
        #expect(!Thread.isMainThread)
        try SystemPresetPackageArchive().createArchive(from: sourceDirectory, at: destinationURL)
    }
    func listEntries(in archiveURL: URL) throws -> [String] {
        #expect(!Thread.isMainThread)
        return try SystemPresetPackageArchive().listEntries(in: archiveURL)
    }
    func extractArchive(at archiveURL: URL, to destinationDirectory: URL) throws {
        #expect(!Thread.isMainThread)
        try SystemPresetPackageArchive().extractArchive(at: archiveURL, to: destinationDirectory)
    }
}

@Test @MainActor func archiveIOLeavesMainActorForBothDirections() async throws {
    let fixture = try PresetPackageFixture()
    defer { fixture.cleanUp() }
    let preset = try fixture.createPreset(name: "Background")
    let service = PresetPackageService(presetStore: fixture.presets, textureStore: fixture.textures.store, archive: BackgroundCheckingArchive())
    _ = try await service.export(presetIDs: [preset.id], to: fixture.packageURL)
    let preview = try await service.prepareImport(from: fixture.packageURL)
    service.discardImport(preview)
}

@Test @MainActor func exportRejectsOversizedManifestString() async throws {
    let fixture = try PresetPackageFixture()
    defer { fixture.cleanUp() }
    let preset = try fixture.createPreset(name: String(repeating: "x", count: 1025))
    await #expect(throws: PresetPackageError.limitsExceeded) {
        try await fixture.service.export(presetIDs: [preset.id], to: fixture.packageURL)
    }
}

@Test @MainActor func backgroundImportCommitsOnlyTheSelectedPresetAndTexture() async throws {
    let source = try PresetPackageFixture()
    let destination = try PresetPackageFixture()
    defer { source.cleanUp(); destination.cleanUp() }
    let image = try source.textures.makeImage(name: "Async", type: .png, width: 32, height: 18)
    let texture = try await source.textures.store.importTexture(from: image)
    let first = try source.createPreset(name: "Selected", textureID: texture.id)
    let second = try source.createPreset(name: "Skipped")
    _ = try await source.service.export(presetIDs: [first.id, second.id], to: source.packageURL)
    let preview = try await destination.service.prepareImport(from: source.packageURL)
    let result = try await destination.service.commitImportInBackground(preview, selectedIDs: [first.id])
    #expect(result == PresetPackageImportResult(presetCount: 1, newTextureCount: 1))
    #expect(destination.presets.userPresets.map(\.name) == ["Selected"])
    #expect(destination.textures.store.resolvedURL(for: texture.id) != nil)
    await #expect(throws: PresetPackageError.previewExpired) {
        try await destination.service.commitImportInBackground(preview, selectedIDs: [first.id])
    }
}

@Test @MainActor func canceledBackgroundImportDoesNotPublishPresets() async throws {
    let fixture = try PresetPackageFixture()
    defer { fixture.cleanUp() }
    let preset = try fixture.createPreset(name: "Original")
    _ = try await fixture.service.export(presetIDs: [preset.id], to: fixture.packageURL)
    let preview = try await fixture.service.prepareImport(from: fixture.packageURL)
    defer { fixture.service.discardImport(preview) }
    let task = Task { try await fixture.service.commitImportInBackground(preview, selectedIDs: [preset.id]) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(fixture.presets.userPresets.count == 1)
}
