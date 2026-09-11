import Foundation
import Testing
@testable import WandelBar

@Test func systemCachePruningOnlyRemovesKnownRetiredRendersAndRetriesLateWrites() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let generated = root.appendingPathComponent("Generated")
    let cache = root.appendingPathComponent("Cache")
    try fm.createDirectory(at: generated, withIntermediateDirectories: true)
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal.json")
    let retired = generated.appendingPathComponent("retired.jpg")
    let active = generated.appendingPathComponent("active.jpg")
    let original = root.appendingPathComponent("original.jpg")
    try Data().write(to: active)
    func cached(_ source: URL) -> URL {
        cache.appendingPathComponent(WallpaperAgentCachePruner.pathHash(source) + "-3024-1964-0-41c817e8f2f52545.bmp")
    }
    let obsolete = cached(retired)
    let preserved = [cached(active), cached(original), cache.appendingPathComponent("cacheVersion.db"),
                     cache.appendingPathComponent(WallpaperAgentCachePruner.pathHash(retired) + "-unknown.bmp")]
    for file in preserved + [obsolete] { try Data("cache".utf8).write(to: file) }
    WallpaperAgentCachePruner.prune(retired: [retired, active, original], generatedDirectory: generated, cacheDirectory: cache, journal: journal, allowsSystemCacheAccess: true)
    #expect(!fm.fileExists(atPath: obsolete.path))
    for file in preserved { #expect(fm.fileExists(atPath: file.path)) }
    try Data("late write".utf8).write(to: obsolete)
    WallpaperAgentCachePruner.prune(retired: [], generatedDirectory: generated, cacheDirectory: cache, journal: journal, allowsSystemCacheAccess: true)
    #expect(!fm.fileExists(atPath: obsolete.path))
    // Never follow a cache entry symlink, even for an otherwise matching name.
    try fm.createSymbolicLink(at: obsolete, withDestinationURL: preserved[0])
    WallpaperAgentCachePruner.prune(retired: [], generatedDirectory: generated, cacheDirectory: cache, journal: journal, allowsSystemCacheAccess: true)
    #expect(try fm.destinationOfSymbolicLink(atPath: obsolete.path) == preserved[0].path)
    #expect(fm.fileExists(atPath: preserved[0].path))
}

@Test func systemCacheAccessIsOptInAndRetirementIsPreserved() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let generated = root.appendingPathComponent("Generated")
    let cache = root.appendingPathComponent("Cache")
    try fm.createDirectory(at: generated, withIntermediateDirectories: true)
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let journal = root.appendingPathComponent("journal.json")
    let retired = generated.appendingPathComponent("retired.jpg")
    let hash = WallpaperAgentCachePruner.pathHash(retired)
    let obsolete = cache.appendingPathComponent(hash + "-3024-1964-0-41c817e8f2f52545.bmp")
    try Data("cache".utf8).write(to: obsolete)
    WallpaperAgentCachePruner.prune(retired: [retired], generatedDirectory: generated, cacheDirectory: cache, journal: journal)
    #expect(fm.fileExists(atPath: obsolete.path))
    #expect(try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: journal)) == [hash])
    // A later launch still leaves the system cache alone until the user opts in.
    WallpaperAgentCachePruner.prune(retired: [], generatedDirectory: generated, cacheDirectory: cache, journal: journal)
    #expect(fm.fileExists(atPath: obsolete.path))
    WallpaperAgentCachePruner.prune(retired: [], generatedDirectory: generated, cacheDirectory: cache, journal: journal, allowsSystemCacheAccess: true)
    #expect(!fm.fileExists(atPath: obsolete.path))
}
