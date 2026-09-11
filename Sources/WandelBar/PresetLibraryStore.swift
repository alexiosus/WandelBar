import Foundation

/// Personal organization stays local and is independent of shared package authorship.
@MainActor
final class PresetLibraryStore {
    private struct Metadata: Codable {
        var favorites: Set<String> = []
        var tags: [String: [String]] = [:]
    }
    private let defaults: UserDefaults
    private let key = "WandelBar.presetLibrary.v1"
    private var metadata: Metadata

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        metadata = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) } ?? Metadata()
    }

    func isFavorite(_ id: String) -> Bool { metadata.favorites.contains(id) }
    func tags(for id: String) -> [String] { metadata.tags[id] ?? [] }

    func toggleFavorite(_ id: String) {
        if !metadata.favorites.insert(id).inserted { metadata.favorites.remove(id) }
        persist()
    }

    func setTags(_ tags: [String], for id: String) {
        var seen = Set<String>()
        metadata.tags[id] = tags.compactMap { value in
            let tag = String(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(32))
            return !tag.isEmpty && seen.insert(tag).inserted ? tag : nil
        }.prefix(12).map { $0 }
        persist()
    }

    func remove(_ id: String) {
        metadata.favorites.remove(id)
        metadata.tags.removeValue(forKey: id)
        persist()
    }

    func matches(_ preset: EffectPreset, query: String, favoritesOnly: Bool) -> Bool {
        guard !favoritesOnly || isFavorite(preset.id) else { return false }
        let terms = query.split(whereSeparator: \.isWhitespace)
        let searchable = ([preset.name] + tags(for: preset.id)).joined(separator: " ")
        return terms.allSatisfy { searchable.localizedStandardContains(String($0)) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(metadata) { defaults.set(data, forKey: key) }
    }
}
