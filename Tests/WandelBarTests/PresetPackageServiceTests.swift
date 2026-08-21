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
