import Foundation

struct ImportedPresetDraft: Equatable, Sendable {
    let name: String
    let settings: WallpaperEffectSettings
}

struct PackageTexturePayload: Equatable, Sendable {
    let sourceID: String
    let name: String
    let pngData: Data
    let sha256: String
}

struct TexturePackageInstallation: Sendable {
    let sourceToLocalID: [String: String]
    let newTextureCount: Int
    let previousAssets: [TextureAsset]
    let previousMetadata: Data?
    let createdFileNames: [String]
}
