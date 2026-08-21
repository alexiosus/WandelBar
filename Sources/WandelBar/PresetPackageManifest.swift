import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let wandelBarPresetPackage = UTType(
        exportedAs: "com.alexeremeev.WandelBar.preset-package",
        conformingTo: .zip
    )
}

struct PresetPackageLimits: Equatable, Sendable {
    let maximumPresets: Int
    let maximumTextures: Int
    let maximumCompressedBytes: Int64
    let maximumExtractedBytes: Int64

    static let `default` = PresetPackageLimits(
        maximumPresets: 100,
        maximumTextures: 100,
        maximumCompressedBytes: 100 * 1024 * 1024,
        maximumExtractedBytes: 200 * 1024 * 1024
    )
}

struct PresetPackageManifest: Codable, Equatable, Sendable {
    static let formatIdentifier = "com.alexeremeev.WandelBar.preset-package"
    static let currentVersion = 1

    let format: String
    let version: Int
    let createdBy: String
    let presets: [Preset]

    init(createdBy: String, presets: [Preset]) {
        self.format = Self.formatIdentifier
        self.version = Self.currentVersion
        self.createdBy = createdBy
        self.presets = presets
    }

    init(format: String, version: Int, createdBy: String, presets: [Preset]) {
        self.format = format
        self.version = version
        self.createdBy = createdBy
        self.presets = presets
    }

    struct Preset: Codable, Equatable, Sendable {
        let sourceID: String
        let name: String
        let settings: WallpaperEffectSettings
        let texture: PresetPackageTextureReference?
    }
}

struct PresetPackageTextureReference: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case builtIn
        case embedded
    }

    let kind: Kind
    let id: String
    let path: String?
    let sha256: String?
}

struct PresetPackagePath: Hashable, Sendable {
    let rawValue: String

    init?(_ rawValue: String) {
        guard !rawValue.isEmpty,
              !rawValue.hasPrefix("/"),
              !rawValue.contains("\\"),
              rawValue == rawValue.precomposedStringWithCanonicalMapping else {
            return nil
        }

        if rawValue == "manifest.json" || rawValue == "textures/" {
            self.rawValue = rawValue
            return
        }

        let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "textures",
              !components[1].hasPrefix("."),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let fileName = String(components[1])
        guard fileName.hasSuffix(".png") else { return nil }
        let digest = fileName.dropLast(4)
        let lowercaseHex = Set("0123456789abcdef")
        guard digest.count == 64,
              digest.allSatisfy({ lowercaseHex.contains($0) }) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

enum PresetImportNameResolver {
    static func resolve(_ incoming: [String], against local: [String]) -> [String] {
        var reserved = Set(local.map(normalized))
        return incoming.map { source in
            let base = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if reserved.insert(normalized(base)).inserted {
                return base
            }

            let imported = "\(base) (Imported)"
            if reserved.insert(normalized(imported)).inserted {
                return imported
            }

            var suffix = 2
            while true {
                let candidate = "\(base) (Imported \(suffix))"
                if reserved.insert(normalized(candidate)).inserted {
                    return candidate
                }
                suffix += 1
            }
        }
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
