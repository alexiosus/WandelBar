import Foundation

extension WallpaperEffectSettings {
    /// SwiftUI/AppKit color bridging can quantize components, so values loaded into a
    /// `Color` do not always round-trip bit-for-bit. The tolerance is far
    /// below any user-visible slider or color-picker adjustment.
    func matchesPresetSettings(_ other: WallpaperEffectSettings) -> Bool {
        let tolerance = 0.000_001
        return abs(blurRadiusPoints - other.blurRadiusPoints) <= tolerance
            && abs(blurLengthPoints - other.blurLengthPoints) <= tolerance
            && abs(fadeLengthPoints - other.fadeLengthPoints) <= tolerance
            && abs(shadowStrength - other.shadowStrength) <= tolerance
            && abs(shadowLengthPoints - other.shadowLengthPoints) <= tolerance
            && abs(tintStrength - other.tintStrength) <= tolerance
            && abs(tintColor.red - other.tintColor.red) <= tolerance
            && abs(tintColor.green - other.tintColor.green) <= tolerance
            && abs(tintColor.blue - other.tintColor.blue) <= tolerance
            && solidTint == other.solidTint
            && abs(saturation - other.saturation) <= tolerance
            && textureID == other.textureID
            && textureBlendMode == other.textureBlendMode
            && abs(textureStrength - other.textureStrength) <= tolerance
            && textureLayoutMode == other.textureLayoutMode
            && abs(textureVerticalPosition - other.textureVerticalPosition) <= tolerance
    }
}

struct EffectPresetSection: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let presets: [EffectPreset]
}

struct EffectPreset: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case builtIn
        case user
    }

    enum BuiltInID {
        static let `default` = "built-in.default"
        static let subtle = "built-in.subtle"
        static let frosted = "built-in.frosted"
        static let clearBlur = "built-in.clear-blur"
        static let smokedGlass = "built-in.smoked-glass"
        static let amethyst = "built-in.amethyst"
        static let dim = "built-in.dim"
        static let dark = "built-in.dark"
        static let solid = "built-in.solid"
        static let blackBar = "built-in.black-bar"
        static let monochrome = "built-in.monochrome"
        static let vivid = "built-in.vivid"
        static let azureGlass = "built-in.azure-glass"
        static let silverGlass = "built-in.silver-glass"
        static let graphiteGlass = "built-in.graphite-glass"
        static let coastalLight = "built-in.coastal-light"
        static let coastalDark = "built-in.coastal-dark"
        static let coastalGlass = "built-in.coastal-glass"
        static let stripedLight = "built-in.striped-light"
        static let stripedDark = "built-in.striped-dark"
        static let stripedGlass = "built-in.striped-glass"
        static let embeddedSlate = "built-in.embedded-slate"
        static let classicBlue = "built-in.classic-blue"
        static let oceanBlue = "built-in.ocean-blue"
        static let royalNoir = "built-in.royal-noir"
        static let classicOlive = "built-in.classic-olive"
    }

    let id: String
    var name: String
    let kind: Kind
    let settings: WallpaperEffectSettings

    init(id: String, name: String, kind: Kind, settings: WallpaperEffectSettings) {
        self.id = id
        self.name = name
        self.kind = kind
        self.settings = settings.clamped
    }

    private static let builtInDefinitions: [EffectPreset] = [
        EffectPreset(id: BuiltInID.default, name: "Default", kind: .builtIn, settings: .default),
        EffectPreset(
            id: BuiltInID.subtle,
            name: "Subtle",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 6,
                blurLengthPoints: 26,
                fadeLengthPoints: 18,
                tintStrength: 0.24,
                tintColor: .black,
                solidTint: false,
                saturation: 0.10
            )
        ),
        EffectPreset(
            id: BuiltInID.frosted,
            name: "Frosted",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 22,
                blurLengthPoints: 38,
                fadeLengthPoints: 36,
                tintStrength: 0.18,
                tintColor: TintColor(red: 0.86, green: 0.88, blue: 0.92),
                solidTint: false,
                saturation: -0.20
            )
        ),
        EffectPreset(
            id: BuiltInID.clearBlur,
            name: "Clear Blur",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 20,
                blurLengthPoints: 34,
                fadeLengthPoints: 30,
                tintStrength: 0,
                tintColor: .black,
                solidTint: false,
                saturation: 0
            )
        ),
        EffectPreset(
            id: BuiltInID.smokedGlass,
            name: "Smoked Glass",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 4.5,
                blurLengthPoints: 28,
                fadeLengthPoints: 0,
                tintStrength: 0.65,
                tintColor: .black,
                solidTint: true,
                saturation: 0.30
            )
        ),
        EffectPreset(
            id: BuiltInID.amethyst,
            name: "Amethyst",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 6.9,
                blurLengthPoints: 30,
                fadeLengthPoints: 0,
                shadowStrength: 1,
                shadowLengthPoints: 9,
                tintStrength: 0.76,
                tintColor: TintColor(
                    red: 107.0 / 255,
                    green: 93.0 / 255,
                    blue: 163.0 / 255
                ),
                solidTint: true,
                saturation: 0
            )
        ),
        EffectPreset(
            id: BuiltInID.dim,
            name: "Dim",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 0,
                blurLengthPoints: 30,
                fadeLengthPoints: 28,
                tintStrength: 0.78,
                tintColor: .black,
                solidTint: false,
                saturation: -0.10
            )
        ),
        EffectPreset(
            id: BuiltInID.dark,
            name: "Dark",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 16,
                blurLengthPoints: 34,
                fadeLengthPoints: 28,
                tintStrength: 0.90,
                tintColor: .black,
                solidTint: false,
                saturation: -0.20
            )
        ),
        EffectPreset(
            id: BuiltInID.solid,
            name: "Translucent Bar",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 0,
                blurLengthPoints: 30,
                fadeLengthPoints: 0,
                tintStrength: 0.75,
                tintColor: .black,
                solidTint: true,
                saturation: 0
            )
        ),
        EffectPreset(
            id: BuiltInID.blackBar,
            name: "Black Bar",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 0,
                blurLengthPoints: 30,
                fadeLengthPoints: 0,
                tintStrength: 1,
                tintColor: .black,
                solidTint: true,
                saturation: 0
            )
        ),
        EffectPreset(
            id: BuiltInID.monochrome,
            name: "Monochrome",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 8,
                blurLengthPoints: 30,
                fadeLengthPoints: 20,
                tintStrength: 0.18,
                tintColor: .black,
                solidTint: false,
                saturation: -1
            )
        ),
        EffectPreset(
            id: BuiltInID.vivid,
            name: "Vivid",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 8,
                blurLengthPoints: 30,
                fadeLengthPoints: 22,
                tintStrength: 0.12,
                tintColor: .black,
                solidTint: false,
                saturation: 1
            )
        ),
        EffectPreset(
            id: BuiltInID.azureGlass,
            name: "Azure Glass",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 3,
                blurLengthPoints: 0,
                fadeLengthPoints: 0,
                shadowStrength: 0,
                shadowLengthPoints: 0,
                tintStrength: 0.65,
                tintColor: TintColor(red: 0.04, green: 0.08, blue: 0.14),
                solidTint: true,
                saturation: 0.15,
                textureID: TextureAsset.azureReflection.id,
                textureBlendMode: .normal,
                textureStrength: 0.30,
                textureLayoutMode: .stretchToBand
            )
        ),
        redmondTexturePreset(
            id: BuiltInID.embeddedSlate,
            name: "Embedded Slate",
            textureID: TextureAsset.embeddedSlate.id
        ),
        redmondTexturePreset(
            id: BuiltInID.classicBlue,
            name: "Classic Blue",
            textureID: TextureAsset.classicBlue.id
        ),
        redmondTexturePreset(
            id: BuiltInID.oceanBlue,
            name: "Ocean Blue",
            textureID: TextureAsset.oceanBlue.id
        ),
        redmondTexturePreset(
            id: BuiltInID.royalNoir,
            name: "Royal Noir",
            textureID: TextureAsset.royalNoir.id
        ),
        redmondTexturePreset(
            id: BuiltInID.classicOlive,
            name: "Classic Olive",
            textureID: TextureAsset.classicOlive.id
        ),
        EffectPreset(
            id: BuiltInID.silverGlass,
            name: "Silver Glass",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 0,
                blurLengthPoints: 24,
                fadeLengthPoints: 0,
                shadowStrength: 1,
                shadowLengthPoints: 15,
                tintStrength: 0.55,
                tintColor: TintColor(red: 0.76, green: 0.78, blue: 0.81),
                solidTint: true,
                saturation: -0.80,
                textureID: TextureAsset.silverGlass.id,
                textureBlendMode: .overlay,
                textureStrength: 0.95,
                textureLayoutMode: .stretchToBand
            )
        ),
        EffectPreset(
            id: BuiltInID.graphiteGlass,
            name: "Graphite Glass",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 50,
                blurLengthPoints: 24,
                fadeLengthPoints: 0,
                shadowStrength: 1,
                shadowLengthPoints: 15,
                tintStrength: 0.90,
                tintColor: TintColor(red: 0.12, green: 0.13, blue: 0.15),
                solidTint: true,
                saturation: -0.85,
                textureID: TextureAsset.graphiteGlass.id,
                textureBlendMode: .overlay,
                textureStrength: 0.90,
                textureLayoutMode: .stretchToBand
            )
        ),
        EffectPreset(
            id: BuiltInID.coastalLight,
            name: "Coastal Light",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 30,
                blurLengthPoints: 24,
                fadeLengthPoints: 0,
                shadowStrength: 1,
                shadowLengthPoints: 15,
                tintStrength: 0.30,
                tintColor: TintColor(red: 1, green: 1, blue: 1),
                solidTint: true,
                saturation: 0.25,
                textureID: TextureAsset.coastalLight.id,
                textureBlendMode: .overlay,
                textureStrength: 0.90,
                textureLayoutMode: .stretchToBand
            )
        ),
        EffectPreset(
            id: BuiltInID.coastalDark,
            name: "Coastal Dark",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 30,
                blurLengthPoints: 24,
                fadeLengthPoints: 0,
                shadowStrength: 1,
                shadowLengthPoints: 15,
                tintStrength: 0.90,
                tintColor: TintColor(red: 0, green: 0, blue: 0),
                solidTint: true,
                saturation: 0.10,
                textureID: TextureAsset.coastalDark.id,
                textureBlendMode: .softLight,
                textureStrength: 1,
                textureLayoutMode: .stretchToBand
            )
        ),
        EffectPreset(
            id: BuiltInID.coastalGlass,
            name: "Coastal Glass",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 30,
                blurLengthPoints: 24,
                fadeLengthPoints: 0,
                shadowStrength: 1,
                shadowLengthPoints: 15,
                tintStrength: 0.18,
                tintColor: TintColor(red: 0.10, green: 0.24, blue: 0.52),
                solidTint: true,
                saturation: 0.20,
                textureID: TextureAsset.coastalLight.id,
                textureBlendMode: .softLight,
                textureStrength: 1,
                textureLayoutMode: .stretchToBand
            )
        ),
        EffectPreset(
            id: BuiltInID.stripedLight,
            name: "Striped Light",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 12.6,
                blurLengthPoints: 24,
                fadeLengthPoints: 0,
                shadowStrength: 1,
                shadowLengthPoints: 15,
                tintStrength: 1.0,
                tintColor: TintColor(
                    red: 1,
                    green: 1,
                    blue: 1
                ),
                solidTint: true,
                saturation: -1,
                textureID: TextureAsset.stripedLight.id,
                textureBlendMode: .multiply,
                textureStrength: 1,
                textureLayoutMode: .stretchToBand
            )
        ),
        EffectPreset(
            id: BuiltInID.stripedDark,
            name: "Striped Dark",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 30,
                blurLengthPoints: 24,
                fadeLengthPoints: 0,
                shadowStrength: 1,
                shadowLengthPoints: 15,
                tintStrength: 1,
                tintColor: .black,
                solidTint: true,
                saturation: -1,
                textureID: TextureAsset.stripedDark.id,
                textureBlendMode: .screen,
                textureStrength: 0.05,
                textureLayoutMode: .stretchToBand
            )
        ),
        EffectPreset(
            id: BuiltInID.stripedGlass,
            name: "Striped Glass",
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 8,
                blurLengthPoints: 24,
                fadeLengthPoints: 0,
                shadowStrength: 1,
                shadowLengthPoints: 15,
                tintStrength: 0.40,
                tintColor: TintColor(red: 0, green: 0, blue: 0),
                solidTint: true,
                saturation: 0.20,
                textureID: TextureAsset.stripedLight.id,
                textureBlendMode: .multiply,
                textureStrength: 0.85,
                textureLayoutMode: .stretchToBand
            )
        )
    ]

    static let builtInSections: [EffectPresetSection] = [
        EffectPresetSection(
            id: "basic",
            title: "Basic",
            presets: presets(withIDs: [
                BuiltInID.default,
                BuiltInID.subtle,
                BuiltInID.frosted,
                BuiltInID.clearBlur
            ])
        ),
        EffectPresetSection(
            id: "color-and-tone",
            title: "Color & Tone",
            presets: presets(withIDs: [
                BuiltInID.smokedGlass,
                BuiltInID.amethyst,
                BuiltInID.dim,
                BuiltInID.dark,
                BuiltInID.solid,
                BuiltInID.blackBar,
                BuiltInID.monochrome,
                BuiltInID.vivid
            ])
        ),
        EffectPresetSection(
            id: "cupertino",
            title: "Cupertino",
            presets: presets(withIDs: [
                BuiltInID.stripedLight,
                BuiltInID.stripedDark,
                BuiltInID.stripedGlass,
                BuiltInID.silverGlass,
                BuiltInID.graphiteGlass,
                BuiltInID.coastalLight,
                BuiltInID.coastalDark,
                BuiltInID.coastalGlass
            ])
        ),
        EffectPresetSection(
            id: "redmond",
            title: "Redmond",
            presets: presets(withIDs: [
                BuiltInID.azureGlass,
                BuiltInID.oceanBlue,
                BuiltInID.classicBlue,
                BuiltInID.classicOlive,
                BuiltInID.embeddedSlate,
                BuiltInID.royalNoir
            ])
        )
    ]

    static let builtIns = builtInSections.flatMap(\.presets)

    private static func presets(withIDs ids: [String]) -> [EffectPreset] {
        ids.map { id in
            guard let preset = builtInDefinitions.first(where: { $0.id == id }) else {
                preconditionFailure("Missing built-in preset definition: \(id)")
            }
            return preset
        }
    }

    private static func redmondTexturePreset(
        id: String,
        name: String,
        textureID: String
    ) -> EffectPreset {
        EffectPreset(
            id: id,
            name: name,
            kind: .builtIn,
            settings: WallpaperEffectSettings(
                blurRadiusPoints: 0,
                blurLengthPoints: 24,
                fadeLengthPoints: 0,
                shadowStrength: 1,
                shadowLengthPoints: 15,
                tintStrength: 0,
                tintColor: .black,
                solidTint: true,
                saturation: 0,
                textureID: textureID,
                textureBlendMode: .normal,
                textureStrength: 1,
                textureLayoutMode: .stretchToBand
            )
        )
    }
}

@MainActor
final class EffectPresetStore {
    enum StoreError: Error, Equatable, LocalizedError {
        case emptyName
        case duplicateName(String)
        case immutablePreset
        case presetNotFound
        case persistenceFailed

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "Enter a preset name."
            case .duplicateName(let name):
                return "A preset named “\(name)” already exists."
            case .immutablePreset:
                return "Built-in presets cannot be changed."
            case .presetNotFound:
                return "That preset no longer exists."
            case .persistenceFailed:
                return "The preset could not be saved."
            }
        }
    }

    static let shared = EffectPresetStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let persistData: ((Data) -> Bool)?
    private var storedUserPresets: [EffectPreset]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "WandelBar.effectPresets.user.v1",
        persistData: ((Data) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.persistData = persistData
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([EffectPreset].self, from: data) {
            storedUserPresets = decoded
                .filter { $0.kind == .user }
                .map {
                    EffectPreset(id: $0.id, name: $0.name, kind: .user, settings: $0.settings)
                }
        } else {
            storedUserPresets = []
        }
    }

    var userPresets: [EffectPreset] {
        storedUserPresets.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var presets: [EffectPreset] {
        EffectPreset.builtIns + userPresets
    }

    func preset(id: String) -> EffectPreset? {
        presets.first { $0.id == id }
    }

    func matchingPreset(for settings: WallpaperEffectSettings) -> EffectPreset? {
        let clamped = settings.clamped
        return presets.first { $0.settings.matchesPresetSettings(clamped) }
    }

    @discardableResult
    func createUserPreset(name: String, settings: WallpaperEffectSettings) throws -> EffectPreset {
        let preset = EffectPreset(
            id: UUID().uuidString,
            name: try validatedName(name),
            kind: .user,
            settings: settings
        )
        try persist(storedUserPresets + [preset])
        return preset
    }

    func renameUserPreset(id: String, name: String) throws {
        if EffectPreset.builtIns.contains(where: { $0.id == id }) {
            throw StoreError.immutablePreset
        }
        guard let index = storedUserPresets.firstIndex(where: { $0.id == id }) else {
            throw StoreError.presetNotFound
        }

        var updated = storedUserPresets
        let existing = updated[index]
        updated[index] = EffectPreset(
            id: existing.id,
            name: try validatedName(name, excludingID: id),
            kind: .user,
            settings: existing.settings
        )
        try persist(updated)
    }

    @discardableResult
    func replaceUserPreset(id: String, settings: WallpaperEffectSettings) throws -> EffectPreset {
        if EffectPreset.builtIns.contains(where: { $0.id == id }) {
            throw StoreError.immutablePreset
        }
        guard let index = storedUserPresets.firstIndex(where: { $0.id == id }) else {
            throw StoreError.presetNotFound
        }

        var updated = storedUserPresets
        let existing = updated[index]
        let replacement = EffectPreset(
            id: existing.id,
            name: existing.name,
            kind: .user,
            settings: settings
        )
        updated[index] = replacement
        try persist(updated)
        return replacement
    }

    func deleteUserPreset(id: String) throws {
        if EffectPreset.builtIns.contains(where: { $0.id == id }) {
            throw StoreError.immutablePreset
        }
        guard storedUserPresets.contains(where: { $0.id == id }) else {
            throw StoreError.presetNotFound
        }
        try persist(storedUserPresets.filter { $0.id != id })
    }

    @discardableResult
    func importUserPresets(_ drafts: [ImportedPresetDraft]) throws -> [EffectPreset] {
        var reservedNames = Set(presets.map { normalizedName($0.name) })
        var imported: [EffectPreset] = []
        imported.reserveCapacity(drafts.count)

        for draft in drafts {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw StoreError.emptyName }
            guard reservedNames.insert(normalizedName(name)).inserted else {
                throw StoreError.duplicateName(name)
            }
            imported.append(EffectPreset(
                id: UUID().uuidString,
                name: name,
                kind: .user,
                settings: draft.settings
            ))
        }

        try persist(storedUserPresets + imported)
        return imported
    }

    private func validatedName(_ name: String, excludingID: String? = nil) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.emptyName }
        let duplicate = presets.contains {
            $0.id != excludingID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !duplicate else { throw StoreError.duplicateName(trimmed) }
        return trimmed
    }

    private func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func persist(_ presets: [EffectPreset]) throws {
        guard let data = try? JSONEncoder().encode(presets) else {
            throw StoreError.persistenceFailed
        }
        if let persistData {
            guard persistData(data) else { throw StoreError.persistenceFailed }
        } else {
            defaults.set(data, forKey: storageKey)
            guard defaults.data(forKey: storageKey) == data else {
                throw StoreError.persistenceFailed
            }
        }
        storedUserPresets = presets
    }
}
