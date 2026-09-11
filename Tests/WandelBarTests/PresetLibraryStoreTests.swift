import Foundation
import Testing
@testable import WandelBar

@Test @MainActor func libraryPersistsFavoritesAndNormalizesSearchableTags() throws {
    let name = "library-tests-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = PresetLibraryStore(defaults: defaults)
    store.toggleFavorite("built-in.default")
    store.setTags([" Glass ", "glass", "BLUE", ""], for: "built-in.default")
    let restored = PresetLibraryStore(defaults: defaults)
    #expect(restored.isFavorite("built-in.default"))
    #expect(restored.tags(for: "built-in.default") == ["glass", "blue"])
    #expect(restored.matches(EffectPreset.builtIns[0], query: "GLASS", favoritesOnly: true))
    #expect(!restored.matches(EffectPreset.builtIns[1], query: "", favoritesOnly: true))
}

@Test @MainActor func textureReferencesIncludeInactiveSpaceOverrides() {
    let name = "texture-refs-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = WallpaperEffectSettingsStore(defaults: defaults)
    var settings = WallpaperEffectSettings.default
    settings.textureID = "custom.hidden"
    store.setOverride(settings, for: "inactive-space")
    store.setEffectEnabled(false, for: "inactive-space")
    #expect(store.referencedTextureIDs.contains("custom.hidden"))
}
