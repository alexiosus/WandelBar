import Foundation
import Testing
@testable import WandelBar

@Test func builtInPresetCatalogIsGroupedAndFlattenedInApprovedOrder() {
    #expect(EffectPreset.builtInSections.map(\.title) == [
        "Basic", "Color & Tone", "Cupertino", "Redmond"
    ])
    #expect(EffectPreset.builtInSections.map { $0.presets.map(\.name) } == [
        ["Default", "Subtle", "Frosted", "Clear Blur"],
        [
            "Smoked Glass", "Amethyst", "Dim", "Dark", "Translucent Bar",
            "Black Bar", "Monochrome", "Vivid"
        ],
        [
            "Striped Light", "Striped Dark", "Striped Glass", "Silver Glass",
            "Graphite Glass", "Coastal Light", "Coastal Dark", "Coastal Glass"
        ],
        [
            "Azure Glass", "Ocean Blue", "Classic Blue", "Classic Olive",
            "Embedded Slate", "Royal Noir"
        ]
    ])
    #expect(EffectPreset.builtIns == EffectPreset.builtInSections.flatMap(\.presets))
    #expect(EffectPreset.builtIns.map(\.id) == [
        "built-in.default",
        "built-in.subtle",
        "built-in.frosted",
        "built-in.clear-blur",
        "built-in.smoked-glass",
        "built-in.amethyst",
        "built-in.dim",
        "built-in.dark",
        "built-in.solid",
        "built-in.black-bar",
        "built-in.monochrome",
        "built-in.vivid",
        "built-in.striped-light",
        "built-in.striped-dark",
        "built-in.striped-glass",
        "built-in.silver-glass",
        "built-in.graphite-glass",
        "built-in.coastal-light",
        "built-in.coastal-dark",
        "built-in.coastal-glass",
        "built-in.azure-glass",
        "built-in.ocean-blue",
        "built-in.classic-blue",
        "built-in.classic-olive",
        "built-in.embedded-slate",
        "built-in.royal-noir"
    ])
    #expect(EffectPreset.builtIns.allSatisfy { $0.kind == .builtIn })
}

@Test func defaultPresetUsesApplicationDefaults() {
    #expect(EffectPreset.builtIns[0].settings == .default)
}

@Test func builtInPresetValuesMatchTheApprovedDesign() throws {
    let presets = Dictionary(uniqueKeysWithValues: EffectPreset.builtIns.map { ($0.name, $0.settings) })
    let smokedGlass = try #require(presets["Smoked Glass"])
    #expect(smokedGlass.blurRadiusPoints == 4.5)
    #expect(smokedGlass.blurLengthPoints == 28)
    #expect(smokedGlass.fadeLengthPoints == 0)
    #expect(smokedGlass.tintColor == .black)
    #expect(smokedGlass.tintStrength == 0.65)
    #expect(smokedGlass.solidTint == true)
    #expect(smokedGlass.saturation == 0.30)
    #expect(smokedGlass.textureID == nil)
    #expect(smokedGlass.textureStrength == 0)

    #expect(presets["Amethyst"] == WallpaperEffectSettings(
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
    ))

    #expect(presets["Subtle"] == WallpaperEffectSettings(
        blurRadiusPoints: 6,
        blurLengthPoints: 26,
        fadeLengthPoints: 18,
        tintStrength: 0.24,
        tintColor: .black,
        solidTint: false,
        saturation: 0.10
    ))
    #expect(presets["Dark"]?.tintStrength == 0.90)
    #expect(presets["Clear Blur"]?.blurRadiusPoints == 20)
    #expect(presets["Clear Blur"]?.tintStrength == 0)
    #expect(presets["Dim"]?.blurRadiusPoints == 0)
    #expect(presets["Dim"]?.solidTint == false)
    #expect(presets["Dim"]?.fadeLengthPoints == 28)
    #expect(presets["Translucent Bar"]?.blurRadiusPoints == 0)
    #expect(presets["Translucent Bar"]?.solidTint == true)
    #expect(presets["Translucent Bar"]?.tintStrength == 0.75)
    #expect(presets["Translucent Bar"]?.fadeLengthPoints == 0)
    #expect(presets["Black Bar"]?.blurRadiusPoints == 0)
    #expect(presets["Black Bar"]?.solidTint == true)
    #expect(presets["Black Bar"]?.tintStrength == 1)
    #expect(presets["Black Bar"]?.fadeLengthPoints == 0)
    #expect(presets["Monochrome"]?.saturation == -1)
    #expect(presets["Vivid"]?.saturation == 1)

    let azure = try #require(presets["Azure Glass"])
    #expect(azure.blurRadiusPoints == 3)
    #expect(azure.blurLengthPoints == 0)
    #expect(azure.fadeLengthPoints == 0)
    #expect(azure.shadowStrength == 0)
    #expect(azure.shadowLengthPoints == 0)
    #expect(azure.tintColor == TintColor(red: 0.04, green: 0.08, blue: 0.14))
    #expect(azure.tintStrength == 0.65)
    #expect(azure.solidTint == true)
    #expect(azure.saturation == 0.15)
    #expect(azure.textureID == TextureAsset.azureReflection.id)
    #expect(azure.textureBlendMode == .normal)
    #expect(azure.textureStrength == 0.30)
    #expect(azure.textureLayoutMode == .stretchToBand)

    let redmondTextures: [(String, String)] = [
        ("Embedded Slate", "built-in.embedded-slate"),
        ("Classic Blue", "built-in.classic-blue"),
        ("Ocean Blue", "built-in.ocean-blue"),
        ("Royal Noir", "built-in.royal-noir"),
        ("Classic Olive", "built-in.classic-olive")
    ]
    for (name, textureID) in redmondTextures {
        let settings = try #require(presets[name])
        #expect(settings.blurRadiusPoints == 0)
        #expect(settings.blurLengthPoints == 24)
        #expect(settings.fadeLengthPoints == 0)
        #expect(settings.shadowStrength == 1)
        #expect(settings.shadowLengthPoints == 15)
        #expect(settings.tintStrength == 0)
        #expect(settings.saturation == 0)
        #expect(settings.textureID == textureID)
        #expect(settings.textureBlendMode == .normal)
        #expect(settings.textureStrength == 1)
        #expect(settings.textureLayoutMode == .stretchToBand)
    }

    let silverGlass = try #require(presets["Silver Glass"])
    #expect(silverGlass.blurRadiusPoints == 0)
    #expect(silverGlass.blurLengthPoints == 24)
    #expect(silverGlass.fadeLengthPoints == 0)
    #expect(silverGlass.tintColor == TintColor(red: 0.76, green: 0.78, blue: 0.81))
    #expect(silverGlass.tintStrength == 0.55)
    #expect(silverGlass.solidTint == true)
    #expect(silverGlass.saturation == -0.80)
    #expect(silverGlass.textureID == TextureAsset.silverGlass.id)
    #expect(silverGlass.textureBlendMode == .overlay)
    #expect(silverGlass.textureStrength == 0.95)
    #expect(silverGlass.textureLayoutMode == .stretchToBand)
    #expect(silverGlass.textureVerticalPosition == 0)

    let graphiteGlass = try #require(presets["Graphite Glass"])
    #expect(graphiteGlass.tintStrength == 0.90)
    #expect(graphiteGlass.tintColor == TintColor(red: 0.12, green: 0.13, blue: 0.15))
    #expect(graphiteGlass.saturation == -0.85)
    #expect(graphiteGlass.textureID == TextureAsset.graphiteGlass.id)
    #expect(graphiteGlass.textureBlendMode == .overlay)
    #expect(graphiteGlass.textureStrength == 0.90)
    #expect(graphiteGlass.textureLayoutMode == .stretchToBand)

    let coastal = try #require(presets["Coastal Light"])
    #expect(coastal.blurRadiusPoints == 30)
    #expect(coastal.blurLengthPoints == 24)
    #expect(coastal.fadeLengthPoints == 0)
    #expect(coastal.tintColor == TintColor(red: 1, green: 1, blue: 1))
    #expect(coastal.tintStrength == 0.30)
    #expect(coastal.solidTint == true)
    #expect(coastal.saturation == 0.25)
    #expect(coastal.textureID == TextureAsset.coastalLight.id)
    #expect(coastal.textureBlendMode == .overlay)
    #expect(coastal.textureStrength == 0.90)
    #expect(coastal.textureLayoutMode == .stretchToBand)
    #expect(coastal.textureVerticalPosition == 0)

    let coastalDark = try #require(presets["Coastal Dark"])
    #expect(coastalDark.blurRadiusPoints == 30)
    #expect(coastalDark.tintStrength == 0.90)
    #expect(coastalDark.tintColor == .black)
    #expect(coastalDark.saturation == 0.10)
    #expect(coastalDark.textureID == TextureAsset.coastalDark.id)
    #expect(coastalDark.textureBlendMode == .softLight)
    #expect(coastalDark.textureStrength == 1)
    #expect(coastalDark.textureLayoutMode == .stretchToBand)

    let coastalGlass = try #require(presets["Coastal Glass"])
    #expect(coastalGlass.blurRadiusPoints == 30)
    #expect(coastalGlass.blurLengthPoints == 24)
    #expect(coastalGlass.fadeLengthPoints == 0)
    #expect(coastalGlass.tintColor == TintColor(red: 0.10, green: 0.24, blue: 0.52))
    #expect(coastalGlass.tintStrength == 0.18)
    #expect(coastalGlass.solidTint == true)
    #expect(coastalGlass.saturation == 0.20)
    #expect(coastalGlass.textureID == TextureAsset.coastalLight.id)
    #expect(coastalGlass.textureBlendMode == .softLight)
    #expect(coastalGlass.textureStrength == 1)
    #expect(coastalGlass.textureLayoutMode == .stretchToBand)

    let striped = try #require(presets["Striped Light"])
    #expect(striped.blurRadiusPoints == 12.6)
    #expect(striped.blurLengthPoints == 24)
    #expect(striped.fadeLengthPoints == 0)
    #expect(striped.tintColor == TintColor(
        red: 1,
        green: 1,
        blue: 1
    ))
    #expect(striped.tintStrength == 1)
    #expect(striped.solidTint == true)
    #expect(striped.saturation == -1)
    #expect(striped.textureID == "built-in.striped-light")
    #expect(striped.textureBlendMode == .multiply)
    #expect(striped.textureStrength == 1)
    #expect(striped.textureLayoutMode == .stretchToBand)
    #expect(striped.textureVerticalPosition == 0)

    let stripedDark = try #require(presets["Striped Dark"])
    #expect(stripedDark.blurRadiusPoints == 30)
    #expect(stripedDark.blurLengthPoints == 24)
    #expect(stripedDark.fadeLengthPoints == 0)
    #expect(stripedDark.tintColor == .black)
    #expect(stripedDark.tintStrength == 1)
    #expect(stripedDark.solidTint == true)
    #expect(stripedDark.saturation == -1)
    #expect(stripedDark.textureID == TextureAsset.stripedDark.id)
    #expect(stripedDark.textureBlendMode == .screen)
    #expect(stripedDark.textureStrength == 0.05)
    #expect(stripedDark.textureLayoutMode == .stretchToBand)
    #expect(stripedDark.textureVerticalPosition == 0)

    let stripedGlass = try #require(presets["Striped Glass"])
    #expect(stripedGlass.blurRadiusPoints == 8)
    #expect(stripedGlass.tintColor == .black)
    #expect(stripedGlass.tintStrength == 0.40)
    #expect(stripedGlass.solidTint == true)
    #expect(stripedGlass.saturation == 0.20)
    #expect(stripedGlass.textureID == "built-in.striped-light")
    #expect(stripedGlass.textureBlendMode == .multiply)
    #expect(stripedGlass.textureStrength == 0.85)
    #expect(stripedGlass.textureLayoutMode == .stretchToBand)
}

@Test func presetMatchingIncludesTextureConfiguration() {
    var expected = WallpaperEffectSettings.default
    expected.textureID = TextureAsset.azureReflection.id
    expected.textureBlendMode = .softLight
    expected.textureStrength = 0.4

    var changed = expected
    changed.textureStrength += 0.01
    #expect(!expected.matchesPresetSettings(changed))

    changed = expected
    changed.textureBlendMode = .overlay
    #expect(!expected.matchesPresetSettings(changed))

    changed = expected
    changed.textureID = "custom.different"
    #expect(!expected.matchesPresetSettings(changed))

    changed = expected
    changed.textureStrength += 0.000_000_5
    #expect(expected.matchesPresetSettings(changed))
}

@Test func classicMenuBarPresetsUseFullFifteenPointShadow() throws {
    let presets = Dictionary(uniqueKeysWithValues: EffectPreset.builtIns.map { ($0.name, $0.settings) })
    let names = [
        "Striped Light", "Striped Dark", "Striped Glass",
        "Silver Glass", "Graphite Glass",
        "Coastal Light", "Coastal Dark", "Coastal Glass"
    ]

    for name in names {
        let settings = try #require(presets[name])
        #expect(settings.shadowStrength == 1)
        #expect(settings.shadowLengthPoints == 15)
    }
}

@Test func presetMatchingIncludesShadowStrengthAndLength() {
    var expected = WallpaperEffectSettings.default
    expected.shadowStrength = 0.30
    expected.shadowLengthPoints = 3

    var changed = expected
    changed.shadowStrength = 0.31
    #expect(!expected.matchesPresetSettings(changed))

    changed = expected
    changed.shadowLengthPoints = 4
    #expect(!expected.matchesPresetSettings(changed))
}

@Test func presetInitializerClampsSettings() {
    let preset = EffectPreset(
        id: "test",
        name: "Test",
        kind: .user,
        settings: WallpaperEffectSettings(
            blurRadiusPoints: 90,
            blurLengthPoints: -5,
            fadeLengthPoints: 500,
            tintStrength: 2,
            tintColor: TintColor(red: -1, green: 0.5, blue: 3),
            solidTint: false,
            saturation: -4
        )
    )
    #expect(preset.settings == preset.settings.clamped)
    #expect(preset.settings.blurRadiusPoints == 30)
    #expect(preset.settings.blurLengthPoints == 0)
}

@MainActor
private func makePresetStore() -> (EffectPresetStore, UserDefaults, String) {
    let suiteName = "WandelBarTests.EffectPresets.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (EffectPresetStore(defaults: defaults, storageKey: "presets"), defaults, suiteName)
}

@Test @MainActor func userPresetCRUDPersistsAcrossStoreInstances() throws {
    let (store, defaults, suiteName) = makePresetStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let created = try store.createUserPreset(name: "  Night  ", settings: .default)
    #expect(created.name == "Night")
    #expect(store.userPresets.map(\.name) == ["Night"])

    let reloaded = EffectPresetStore(defaults: defaults, storageKey: "presets")
    #expect(reloaded.preset(id: created.id)?.settings == .default)

    try reloaded.renameUserPreset(id: created.id, name: "Evening")
    #expect(reloaded.userPresets.map(\.name) == ["Evening"])

    try reloaded.deleteUserPreset(id: created.id)
    #expect(reloaded.userPresets.isEmpty)
}

@Test @MainActor func userPresetNamesAreValidatedCaseInsensitively() throws {
    let (store, defaults, suiteName) = makePresetStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(throws: EffectPresetStore.StoreError.emptyName) {
        try store.createUserPreset(name: "   ", settings: .default)
    }
    #expect(throws: EffectPresetStore.StoreError.duplicateName("default")) {
        try store.createUserPreset(name: " default ", settings: .default)
    }
    _ = try store.createUserPreset(name: "Night", settings: .default)
    #expect(throws: EffectPresetStore.StoreError.duplicateName("NIGHT")) {
        try store.createUserPreset(name: "NIGHT", settings: .default)
    }
}

@Test @MainActor func replacingUserPresetKeepsItsIdentityAndUpdatesItsSettings() throws {
    let (store, defaults, suiteName) = makePresetStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let original = try store.createUserPreset(name: "Night", settings: .default)
    let replacementSettings = try #require(
        EffectPreset.builtIns.first { $0.id == EffectPreset.BuiltInID.blackBar }
    ).settings

    let replaced = try store.replaceUserPreset(
        id: original.id,
        settings: replacementSettings
    )

    #expect(replaced.id == original.id)
    #expect(replaced.name == "Night")
    #expect(replaced.settings == replacementSettings)
    #expect(store.userPresets == [replaced])
}

@Test @MainActor func builtInPresetCannotBeReplaced() {
    let (store, defaults, suiteName) = makePresetStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(throws: EffectPresetStore.StoreError.immutablePreset) {
        try store.replaceUserPreset(
            id: EffectPreset.BuiltInID.default,
            settings: EffectPreset.builtIns[1].settings
        )
    }
}

@Test @MainActor func userPresetsAreSortedAndBuiltInsRemainFirst() throws {
    let (store, defaults, suiteName) = makePresetStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    _ = try store.createUserPreset(name: "zebra", settings: .default)
    _ = try store.createUserPreset(name: "Amber", settings: .default)
    #expect(store.presets.prefix(EffectPreset.builtIns.count).allSatisfy { $0.kind == .builtIn })
    #expect(store.userPresets.map(\.name) == ["Amber", "zebra"])
}

@Test @MainActor func matchingPrefersBuiltInPreset() throws {
    let (store, defaults, suiteName) = makePresetStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    _ = try store.createUserPreset(name: "My Default", settings: .default)
    #expect(store.matchingPreset(for: .default)?.id == EffectPreset.BuiltInID.default)
}

@Test @MainActor func builtInsAndUnknownIDsCannotBeMutated() {
    let (store, defaults, suiteName) = makePresetStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    #expect(throws: EffectPresetStore.StoreError.immutablePreset) {
        try store.renameUserPreset(id: EffectPreset.BuiltInID.default, name: "Changed")
    }
    #expect(throws: EffectPresetStore.StoreError.presetNotFound) {
        try store.deleteUserPreset(id: "missing")
    }
}

@Test @MainActor func corruptStorageFallsBackToBuiltIns() {
    let (_, defaults, suiteName) = makePresetStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data("not-json".utf8), forKey: "presets")
    let reloaded = EffectPresetStore(defaults: defaults, storageKey: "presets")
    #expect(reloaded.userPresets.isEmpty)
    #expect(reloaded.presets == EffectPreset.builtIns)
}

@Test @MainActor func importedPresetBatchUsesNewIDsAndOnePersistenceWrite() throws {
    let suiteName = "WandelBarTests.EffectPresets.Batch.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var writeCount = 0
    let store = EffectPresetStore(
        defaults: defaults,
        storageKey: "presets",
        persistData: { data in
            writeCount += 1
            defaults.set(data, forKey: "presets")
            return defaults.data(forKey: "presets") == data
        }
    )

    let imported = try store.importUserPresets([
        ImportedPresetDraft(name: "One", settings: .default),
        ImportedPresetDraft(name: "Two", settings: .default)
    ])

    #expect(imported.map(\.name) == ["One", "Two"])
    #expect(Set(imported.map(\.id)).count == 2)
    #expect(writeCount == 1)
}

@Test @MainActor func invalidImportedPresetBatchDoesNotPersistAnything() {
    var writeCount = 0
    let store = EffectPresetStore(persistData: { _ in
        writeCount += 1
        return true
    })

    #expect(throws: EffectPresetStore.StoreError.duplicateName("one")) {
        try store.importUserPresets([
            ImportedPresetDraft(name: "One", settings: .default),
            ImportedPresetDraft(name: "one", settings: .default)
        ])
    }
    #expect(store.userPresets.isEmpty)
    #expect(writeCount == 0)
}
