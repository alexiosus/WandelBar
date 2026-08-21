import Foundation

/// An sRGB tint color stored as plain components so it stays `Codable`/`Sendable`.
struct TintColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = TintColor(red: 0, green: 0, blue: 0)

    var clamped: TintColor {
        TintColor(
            red: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1)
        )
    }
}

enum TextureBlendMode: String, Codable, CaseIterable, Equatable, Sendable {
    case normal
    case screen
    case multiply
    case softLight
    case overlay

    var displayName: String {
        switch self {
        case .normal:
            return "Normal"
        case .screen:
            return "Screen"
        case .multiply:
            return "Multiply"
        case .softLight:
            return "Soft Light"
        case .overlay:
            return "Overlay"
        }
    }
}

enum TextureLayoutMode: String, Codable, CaseIterable, Equatable, Sendable {
    case fitWidth
    case fillBand
    case stretchToBand

    var displayName: String {
        switch self {
        case .fitWidth:
            return "Fit Width"
        case .fillBand:
            return "Fill Band"
        case .stretchToBand:
            return "Stretch to Band"
        }
    }

    /// Stretching already maps the complete source image to the band, so there is no
    /// cropped content to move vertically. The other layouts may crop and can use an
    /// alignment offset.
    var usesVerticalPosition: Bool {
        self != .stretchToBand
    }
}

struct WallpaperEffectSettings: Codable, Equatable, Sendable {
    var blurRadiusPoints: Double
    /// Height of the fully-blurred (solid) region. May be shorter than the menu bar, in
    /// which case the fade below it starts inside the bar; the renderer still floors the
    /// whole band at the menu-bar height so the bar always stays covered.
    var blurLengthPoints: Double
    /// Length of the soft gradient tail below the solid region, in points. `0` gives a
    /// crisp edge; larger values extend the band downward (past the menu bar) for a more
    /// gradual transition.
    var fadeLengthPoints: Double
    /// Opacity of the shadow below a crisp band, 0...1. The renderer ignores it while
    /// Fade is greater than zero, but the value remains stored for later reuse.
    var shadowStrength: Double = 0
    /// Vertical reach of the shadow in points, 0...32.
    var shadowLengthPoints: Double = 3
    /// Strength of the color wash over the band, 0...1.
    var tintStrength: Double
    /// Color of the wash. A dark tint reproduces the old "dim" behavior.
    var tintColor: TintColor
    /// When `true` the tint is a uniform layer that reaches a fully opaque color at
    /// full strength; when `false` it's a gradient wash that fades toward the band's
    /// lower edge and never fully hides the wallpaper.
    var solidTint: Bool
    /// Saturation of the band, -1...1 (−1 = grayscale, 0 = unchanged, +1 = doubled).
    var saturation: Double
    /// Stable identifier resolved by `TextureAssetStore`; `nil` disables texture rendering.
    var textureID: String? = nil
    var textureBlendMode: TextureBlendMode = .screen
    /// Opacity contribution of the texture layer, 0...1.
    var textureStrength: Double = 0
    var textureLayoutMode: TextureLayoutMode = .fitWidth
    /// Vertical alignment from -1 (bottom) through 0 (center) to 1 (top).
    var textureVerticalPosition: Double = 0

    private enum CodingKeys: String, CodingKey {
        case blurRadiusPoints, blurLengthPoints, fadeLengthPoints
        case shadowStrength, shadowLengthPoints
        case tintStrength, tintColor, solidTint, saturation
        case textureID, textureBlendMode, textureStrength, textureLayoutMode, textureVerticalPosition
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case shadowEnabled
    }

    static let `default` = WallpaperEffectSettings(
        // 40% of the 0...30 blur range.
        blurRadiusPoints: 12,
        // A solid region roughly covering the bar plus a soft tail; the whole thing is
        // floored at the menu bar in the renderer, so the band covers the bar and fades
        // just below.
        blurLengthPoints: 30,
        fadeLengthPoints: 24,
        tintStrength: 0.5,
        tintColor: .black,
        solidTint: false,
        saturation: 0.3
    )
}

@MainActor
final class WallpaperEffectSettingsStore {
    static let shared = WallpaperEffectSettingsStore()

    private enum DefaultsKey {
        // Bump the version suffix to reset everyone to a new default set.
        static let effectSettings = "WandelBar.effectSettings.v5"
        static let perSpaceSettings = "WandelBar.effectSettings.perSpace.v2"
        static let disabledSpaces = "WandelBar.effectSettings.disabledSpaces.v1"
    }

    private let defaults: UserDefaults
    private let effectSettingsKey: String
    private let perSpaceSettingsKey: String
    private let disabledSpacesKey: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.effectSettingsKey = DefaultsKey.effectSettings
        self.perSpaceSettingsKey = DefaultsKey.perSpaceSettings
        self.disabledSpacesKey = DefaultsKey.disabledSpaces
    }

    /// The settings used by any Space that has not been individually customized.
    var global: WallpaperEffectSettings {
        get {
            guard let data = defaults.data(forKey: effectSettingsKey),
                  let settings = try? JSONDecoder().decode(WallpaperEffectSettings.self, from: data) else {
                return .default
            }

            return settings.clamped
        }
        set {
            let normalized = newValue.clamped
            if let data = try? JSONEncoder().encode(normalized) {
                defaults.set(data, forKey: effectSettingsKey)
            }
        }
    }

    private var overrides: [String: WallpaperEffectSettings] {
        get {
            guard let data = defaults.data(forKey: perSpaceSettingsKey) else {
                return [:]
            }

            return (try? JSONDecoder().decode([String: WallpaperEffectSettings].self, from: data)) ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: perSpaceSettingsKey)
            }
        }
    }

    /// The per-Space override for `space`, if that Space has been customized.
    func override(for space: String) -> WallpaperEffectSettings? {
        overrides[space]?.clamped
    }

    /// Sets (or, with `nil`, clears) the per-Space override for `space`.
    func setOverride(_ settings: WallpaperEffectSettings?, for space: String) {
        var updated = overrides
        if let settings {
            updated[space] = settings.clamped
        } else {
            updated.removeValue(forKey: space)
        }
        overrides = updated
    }

    private var disabledSpaces: Set<String> {
        get {
            guard let values = defaults.array(forKey: disabledSpacesKey) as? [String] else {
                return []
            }
            return Set(values)
        }
        set {
            defaults.set(newValue.sorted(), forKey: disabledSpacesKey)
        }
    }

    func isEffectEnabled(for space: String?) -> Bool {
        guard let space else { return true }
        return !disabledSpaces.contains(space)
    }

    func setEffectEnabled(_ enabled: Bool, for space: String) {
        var updated = disabledSpaces
        if enabled {
            updated.remove(space)
        } else {
            updated.insert(space)
        }
        disabledSpaces = updated
    }

    func enabledSettings(for space: String?) -> WallpaperEffectSettings? {
        guard isEffectEnabled(for: space) else { return nil }
        return effectiveSettings(for: space)
    }

    /// The settings that apply to `space`: its override if customized, otherwise global.
    func effectiveSettings(for space: String?) -> WallpaperEffectSettings {
        if let space, let override = override(for: space) {
            return override
        }
        return global
    }
}

extension WallpaperEffectSettings {
    // Custom decoder so a value missing an optional key (e.g. `fadeLengthPoints`) still
    // loads with a sensible default instead of falling back to `.default`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blurRadiusPoints = try container.decode(Double.self, forKey: .blurRadiusPoints)
        blurLengthPoints = try container.decode(Double.self, forKey: .blurLengthPoints)
        fadeLengthPoints = try container.decodeIfPresent(Double.self, forKey: .fadeLengthPoints) ?? 24
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyShadowEnabled = try legacyContainer.decodeIfPresent(
            Bool.self,
            forKey: .shadowEnabled
        ) ?? false
        shadowStrength = try container.decodeIfPresent(Double.self, forKey: .shadowStrength)
            ?? (legacyShadowEnabled ? 0.30 : 0)
        shadowLengthPoints = try container.decodeIfPresent(Double.self, forKey: .shadowLengthPoints) ?? 3
        tintStrength = try container.decode(Double.self, forKey: .tintStrength)
        tintColor = try container.decode(TintColor.self, forKey: .tintColor)
        solidTint = try container.decodeIfPresent(Bool.self, forKey: .solidTint) ?? false
        saturation = try container.decode(Double.self, forKey: .saturation)
        textureID = try container.decodeIfPresent(String.self, forKey: .textureID)
        textureBlendMode = (try? container.decode(TextureBlendMode.self, forKey: .textureBlendMode)) ?? .screen
        textureStrength = try container.decodeIfPresent(Double.self, forKey: .textureStrength) ?? 0
        textureLayoutMode = (try? container.decode(TextureLayoutMode.self, forKey: .textureLayoutMode)) ?? .fitWidth
        textureVerticalPosition = try container.decodeIfPresent(
            Double.self,
            forKey: .textureVerticalPosition
        ) ?? 0
    }

    var clamped: WallpaperEffectSettings {
        let normalizedTextureID = textureID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableTextureID = normalizedTextureID?.isEmpty == false ? normalizedTextureID : nil

        return WallpaperEffectSettings(
            blurRadiusPoints: min(max(blurRadiusPoints, 0), 30),
            // Solid region can be as short as 0 (fade starts at the very top); the renderer
            // floors the whole band at the menu-bar height, so coverage is never lost.
            blurLengthPoints: min(max(blurLengthPoints, 0), 260),
            fadeLengthPoints: min(max(fadeLengthPoints, 0), 160),
            shadowStrength: min(max(shadowStrength, 0), 1),
            shadowLengthPoints: min(max(shadowLengthPoints, 0), 32),
            tintStrength: min(max(tintStrength, 0), 1),
            tintColor: tintColor.clamped,
            solidTint: solidTint,
            saturation: min(max(saturation, -1), 1),
            textureID: usableTextureID,
            textureBlendMode: usableTextureID == nil ? .screen : textureBlendMode,
            textureStrength: usableTextureID == nil ? 0 : min(max(textureStrength, 0), 1),
            textureLayoutMode: usableTextureID == nil ? .fitWidth : textureLayoutMode,
            textureVerticalPosition: usableTextureID == nil
                ? 0
                : min(max(textureVerticalPosition, -1), 1)
        )
    }
}
