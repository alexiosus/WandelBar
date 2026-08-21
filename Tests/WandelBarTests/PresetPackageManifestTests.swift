import Foundation
import Testing
@testable import WandelBar

@Test func presetPackageManifestRoundTripsEverySetting() throws {
    var settings = WallpaperEffectSettings.default
    settings.blurRadiusPoints = 17
    settings.shadowStrength = 0.7
    settings.textureID = "custom.abc"
    settings.textureBlendMode = .softLight
    settings.textureStrength = 0.8
    settings.textureLayoutMode = .fitWidth
    settings.textureVerticalPosition = -0.25

    let manifest = PresetPackageManifest(
        createdBy: "0.1.0",
        presets: [.init(
            sourceID: "source",
            name: "Shared Glass",
            settings: settings,
            texture: .init(
                kind: .embedded,
                id: "custom.abc",
                path: "textures/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png",
                sha256: String(repeating: "a", count: 64)
            )
        )]
    )

    let decoded = try JSONDecoder().decode(
        PresetPackageManifest.self,
        from: JSONEncoder().encode(manifest)
    )
    #expect(decoded == manifest)
    #expect(decoded.format == "com.alexeremeev.WandelBar.preset-package")
    #expect(decoded.version == 1)
}

@Test(arguments: [
    "../manifest.json", "/tmp/payload", "textures\\evil.png",
    "textures/../evil.png", "textures/.hidden.png", "__MACOSX/junk"
])
func unsafePackagePathsAreRejected(_ path: String) {
    #expect(PresetPackagePath(path) == nil)
}

@Test(arguments: [
    "manifest.json",
    "textures/",
    "textures/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png"
])
func expectedPackagePathsAreAccepted(_ path: String) {
    #expect(PresetPackagePath(path)?.rawValue == path)
}

@Test func importedNamesNeverOverwriteLocalOrEarlierImportedNames() {
    #expect(PresetImportNameResolver.resolve(
        ["Ocean", "Ocean", "ocean", "Night"],
        against: ["Ocean", "Ocean (Imported)"]
    ) == ["Ocean (Imported 2)", "Ocean (Imported 3)", "ocean (Imported 4)", "Night"])
}
