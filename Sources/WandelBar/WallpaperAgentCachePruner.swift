import Foundation
import CryptoKit

/// macOS currently keys image-cache BMPs by SHA256 of the source filesystem path.
/// This is an observed, private format: unknown names are deliberately left alone.
/// Only paths of retired WandelBar renders are recorded, never original wallpapers.
enum WallpaperAgentCachePruner {
    static let automaticCleanupKey = "automaticallyCleanSystemWallpaperCache"

    private static let queue = DispatchQueue(label: "WandelBar.wallpaper-cache", qos: .utility)

    static func schedule(retired: [URL], generatedDirectory: URL) {
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/com.apple.wallpaper.caches/extension-com.apple.wallpaper.extension.image",
            isDirectory: true
        )
        let journal = generatedDirectory.deletingLastPathComponent()
            .appendingPathComponent("RetiredWallpaperCachePaths.json")
        queue.async {
            prune(retired: retired, generatedDirectory: generatedDirectory, cacheDirectory: cache, journal: journal,
                  allowsSystemCacheAccess: UserDefaults.standard.bool(forKey: automaticCleanupKey))
        }
        // The wallpaper agent may still be finishing an asynchronous cache write.
        // Persisted hashes also allow a later launch to retry missed/denied removals.
        queue.asyncAfter(deadline: .now() + 20) {
            prune(retired: [], generatedDirectory: generatedDirectory, cacheDirectory: cache, journal: journal,
                  allowsSystemCacheAccess: UserDefaults.standard.bool(forKey: automaticCleanupKey))
        }
    }

    static func pathHash(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func prune(retired: [URL], generatedDirectory: URL, cacheDirectory: URL, journal: URL, allowsSystemCacheAccess: Bool = false) {
        let fm = FileManager.default
        var hashes = Set<String>()
        if fm.fileExists(atPath: journal.path) {
            guard let data = try? Data(contentsOf: journal),
                  let saved = try? JSONDecoder().decode(Set<String>.self, from: data) else { return }
            hashes = saved
        }
        let previous = hashes
        for url in retired where GeneratedWallpaperPaths.contains(url, in: generatedDirectory) {
            // A still-existing source is not retired; preserve its cache.
            guard !fm.fileExists(atPath: url.path) else { continue }
            hashes.insert(pathHash(url))
        }
        if hashes != previous {
            guard let data = try? JSONEncoder().encode(hashes),
                  (try? data.write(to: journal, options: .atomic)) != nil else { return }
        }
        // Recording retirement only touches our own support directory. Even metadata
        // queries in another app's container can trigger macOS App Data Protection.
        guard allowsSystemCacheAccess else { return }
        guard !hashes.isEmpty,
              let root = try? cacheDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              root.isDirectory == true, root.isSymbolicLink != true,
              let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for file in files {
            let name = file.lastPathComponent
            guard name.range(of: "^[0-9a-f]{64}-[0-9]+-[0-9]+-0-[0-9a-f]{16}\\.bmp$", options: .regularExpression) != nil,
                  hashes.contains(String(name.prefix(64))),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? fm.removeItem(at: file)
        }
    }
}
