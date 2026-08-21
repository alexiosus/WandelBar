import Foundation

struct OriginalCachePruner {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prune(
        directories: [URL],
        preserving referencedURLs: [URL],
        olderThan cutoff: Date
    ) {
        let preservedPaths = Set(
            referencedURLs
                .filter(\.isFileURL)
                .map { $0.standardizedFileURL.path }
        )

        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else {
                continue
            }

            for file in files {
                let path = file.standardizedFileURL.path
                guard !preservedPaths.contains(path) else { continue }

                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < cutoff {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }
}

enum WallpaperFileValidator {
    static func isReadableRegularFile(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard url.isFileURL, fileManager.isReadableFile(atPath: url.path) else {
            return false
        }

        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

enum GeneratedWallpaperPaths {
    static func contains(_ candidate: URL, in directory: URL) -> Bool {
        guard candidate.isFileURL, directory.isFileURL else { return false }

        let directoryPath = directory.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath.hasPrefix(directoryPath + "/")
    }
}

enum WallpaperCurrentness {
    static func isCurrent(
        expected: WallpaperIdentity,
        storeIdentity: WallpaperIdentity?,
        workspaceURL: URL?,
        generatedDirectory: URL
    ) -> Bool {
        if let storeIdentity,
           !isGenerated(storeIdentity, generatedDirectory: generatedDirectory) {
            return storeIdentity.stableIdentifier == expected.stableIdentifier
        }

        guard let workspaceURL else {
            // An unreadable private store and no public fallback is uncertainty, not proof
            // that a background render still belongs to the current wallpaper.
            return false
        }

        if GeneratedWallpaperPaths.contains(workspaceURL, in: generatedDirectory) {
            // The app's own wallpaper is still applied and neither display/Space nor the
            // generation revision changed. The saved original remains the current source.
            return true
        }

        return WallpaperIdentity.file(workspaceURL).stableIdentifier == expected.stableIdentifier
    }

    private static func isGenerated(
        _ identity: WallpaperIdentity,
        generatedDirectory: URL
    ) -> Bool {
        guard let url = identity.fileURL else { return false }
        return GeneratedWallpaperPaths.contains(url, in: generatedDirectory)
    }
}

enum WallpaperRefreshPolicy {
    static func shouldRefresh(
        workspaceURL: URL?,
        storeIdentity: WallpaperIdentity?,
        savedSourceIdentity: String?,
        savedURL: URL?,
        generatedDirectory: URL
    ) -> Bool {
        guard let workspaceURL else { return true }
        guard GeneratedWallpaperPaths.contains(workspaceURL, in: generatedDirectory) else {
            return true
        }

        guard let storeIdentity else {
            return false
        }

        if let fileURL = storeIdentity.fileURL,
           GeneratedWallpaperPaths.contains(fileURL, in: generatedDirectory) {
            return false
        }

        let savedIdentity = savedSourceIdentity
            ?? savedURL.map { WallpaperIdentity.file($0).stableIdentifier }
        return savedIdentity != storeIdentity.stableIdentifier
    }
}

enum WallpaperRestorePolicy {
    /// Turning WandelBar off restores the wallpaper it replaced. That is wrong once the
    /// user has moved on to a wallpaper WandelBar never touched — restoring would drop a
    /// still image on top of their video wallpaper. The stored original is dropped instead.
    static func shouldAbandonStoredOriginal(
        currentIsGenerated: Bool,
        unsupportedReason: String?
    ) -> Bool {
        !currentIsGenerated && unsupportedReason != nil
    }
}

enum GeneratedWallpaperRecovery {
    static func storedDesktop(
        matching generatedURL: URL,
        displayIDs: [String],
        in saved: [String: StoredDesktop]
    ) -> StoredDesktop? {
        let generatedPath = generatedURL.standardizedFileURL.path
        let uniqueDisplayIDs = Set(displayIDs)

        return saved.first { element in
            let (key, desktop) = element
            let belongsToDisplay = uniqueDisplayIDs.contains(key)
                || uniqueDisplayIDs.contains { key.hasPrefix($0 + "::") }
            guard belongsToDisplay, let storedPath = desktop.generatedPath else {
                return false
            }
            return URL(fileURLWithPath: storedPath).standardizedFileURL.path == generatedPath
        }?.value
    }
}
