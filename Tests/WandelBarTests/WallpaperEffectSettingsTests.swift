import Foundation
import Testing
@testable import WandelBar

@Test func settingsAreClampedAtPersistenceBoundaries() {
    let settings = WallpaperEffectSettings(
        blurRadiusPoints: 100,
        blurLengthPoints: -1,
        fadeLengthPoints: 999,
        tintStrength: -3,
        tintColor: TintColor(red: -1, green: 0.5, blue: 2),
        solidTint: true,
        saturation: 4
    ).clamped

    #expect(settings.blurRadiusPoints == 30)
    #expect(settings.blurLengthPoints == 0)
    #expect(settings.fadeLengthPoints == 160)
    #expect(settings.tintStrength == 0)
    #expect(settings.tintColor == TintColor(red: 0, green: 0.5, blue: 1))
    #expect(settings.saturation == 1)
}

@Test func legacySettingsDecodeWithoutTextureKeys() throws {
    let json = #"""
    {
      "blurRadiusPoints":12,
      "blurLengthPoints":30,
      "fadeLengthPoints":24,
      "tintStrength":0.5,
      "tintColor":{"red":0,"green":0,"blue":0},
      "solidTint":false,
      "saturation":0.3
    }
    """#

    let settings = try JSONDecoder().decode(
        WallpaperEffectSettings.self,
        from: Data(json.utf8)
    )

    #expect(settings.textureID == nil)
    #expect(settings.textureBlendMode == .screen)
    #expect(settings.textureStrength == 0)
    #expect(settings.textureLayoutMode == .fitWidth)
    #expect(settings.textureVerticalPosition == 0)
    #expect(settings.shadowStrength == 0)
    #expect(settings.shadowLengthPoints == 3)
}

@Test func legacyShadowToggleMigratesToDefaultStrengthAndLength() throws {
    let json = #"""
    {
      "blurRadiusPoints":12,
      "blurLengthPoints":30,
      "fadeLengthPoints":0,
      "shadowEnabled":true,
      "tintStrength":0.5,
      "tintColor":{"red":0,"green":0,"blue":0},
      "solidTint":false,
      "saturation":0.3
    }
    """#

    let settings = try JSONDecoder().decode(
        WallpaperEffectSettings.self,
        from: Data(json.utf8)
    )

    #expect(settings.shadowStrength == 0.30)
    #expect(settings.shadowLengthPoints == 3)
}

@Test func textureLayoutSettingsClampAndNormalizeNone() {
    var active = WallpaperEffectSettings.default
    active.textureID = TextureAsset.azureReflection.id
    active.textureLayoutMode = .fillBand
    active.textureVerticalPosition = 7
    #expect(active.clamped.textureLayoutMode == .fillBand)
    #expect(active.clamped.textureVerticalPosition == 1)

    active.textureID = nil
    #expect(active.clamped.textureLayoutMode == .fitWidth)
    #expect(active.clamped.textureVerticalPosition == 0)
}

@Test func shadowSettingsClampToSupportedSliderRanges() {
    var settings = WallpaperEffectSettings.default
    settings.shadowStrength = 4
    settings.shadowLengthPoints = 80

    let upper = settings.clamped
    #expect(upper.shadowStrength == 1)
    #expect(upper.shadowLengthPoints == 32)

    settings.shadowStrength = -1
    settings.shadowLengthPoints = -8
    let lower = settings.clamped
    #expect(lower.shadowStrength == 0)
    #expect(lower.shadowLengthPoints == 0)
}

@Test func textureSettingsClampAndNormalizeNone() {
    var active = WallpaperEffectSettings.default
    active.textureID = TextureAsset.azureReflection.id
    active.textureBlendMode = .overlay
    active.textureStrength = 8
    #expect(active.clamped.textureStrength == 1)
    #expect(active.clamped.textureBlendMode == .overlay)

    active.textureID = "   "
    let none = active.clamped
    #expect(none.textureID == nil)
    #expect(none.textureBlendMode == .screen)
    #expect(none.textureStrength == 0)
}

@Test func texturePositionIsOnlyOfferedWhenTheLayoutCanUseIt() {
    #expect(TextureLayoutMode.fitWidth.usesVerticalPosition)
    #expect(TextureLayoutMode.fillBand.usesVerticalPosition)
    #expect(!TextureLayoutMode.stretchToBand.usesVerticalPosition)
}

@Test @MainActor func matchingSpaceOverrideRemainsExplicit() {
    let suiteName = "WandelBarTests.SettingsStore.MatchingOverride.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WallpaperEffectSettingsStore(defaults: defaults)
    let space = "space-one"
    var custom = WallpaperEffectSettings.default
    custom.blurRadiusPoints = 27

    store.setOverride(custom, for: space)
    #expect(store.override(for: space) == custom)

    let matchingDefault = store.global
    store.setOverride(matchingDefault, for: space)

    #expect(store.override(for: space) == matchingDefault)
    #expect(store.effectiveSettings(for: space) == matchingDefault)
}

@Test @MainActor func changingDefaultPreservesOverridesThatNowMatchIt() {
    let suiteName = "WandelBarTests.SettingsStore.DefaultPruning.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WallpaperEffectSettingsStore(defaults: defaults)
    var matching = WallpaperEffectSettings.default
    matching.blurRadiusPoints = 22
    var distinct = WallpaperEffectSettings.default
    distinct.blurRadiusPoints = 6
    store.setOverride(matching, for: "matching")
    store.setOverride(distinct, for: "distinct")

    store.global = matching

    #expect(store.override(for: "matching") == matching)
    #expect(store.override(for: "distinct") == distinct)
}

@Test @MainActor func readingLegacyMatchingOverridePreservesIt() throws {
    let suiteName = "WandelBarTests.SettingsStore.LegacyRedundantOverride.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let key = "WandelBar.effectSettings.perSpace.v2"
    let space = "legacy-space"
    defaults.set(
        try JSONEncoder().encode([space: WallpaperEffectSettings.default]),
        forKey: key
    )
    let store = WallpaperEffectSettingsStore(defaults: defaults)

    #expect(store.override(for: space) == WallpaperEffectSettings.default)

    let persisted = try JSONDecoder().decode(
        [String: WallpaperEffectSettings].self,
        from: defaults.data(forKey: key)!
    )
    #expect(persisted[space] == WallpaperEffectSettings.default)
}

@Test @MainActor func disablingASpacePersistsWithoutRemovingItsSettingsOverride() {
    let suiteName = "WandelBarTests.SettingsStore.DisabledSpace.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let space = "disabled-space"
    var custom = WallpaperEffectSettings.default
    custom.blurRadiusPoints = 7

    let store = WallpaperEffectSettingsStore(defaults: defaults)
    store.setOverride(custom, for: space)
    store.setEffectEnabled(false, for: space)

    let reloaded = WallpaperEffectSettingsStore(defaults: defaults)
    #expect(!reloaded.isEffectEnabled(for: space))
    #expect(reloaded.override(for: space) == custom)
    #expect(reloaded.enabledSettings(for: space) == nil)
}

@Test @MainActor func reenablingASpaceRestoresItsPreviousSettingsOverride() {
    let suiteName = "WandelBarTests.SettingsStore.ReenabledSpace.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let space = "reenabled-space"
    var custom = WallpaperEffectSettings.default
    custom.blurLengthPoints = 91
    let store = WallpaperEffectSettingsStore(defaults: defaults)
    store.setOverride(custom, for: space)
    store.setEffectEnabled(false, for: space)

    store.setEffectEnabled(true, for: space)

    #expect(store.isEffectEnabled(for: space))
    #expect(store.override(for: space) == custom)
    #expect(store.enabledSettings(for: space) == custom)
}
