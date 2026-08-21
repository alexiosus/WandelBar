import AppKit
import Darwin
import Photos
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum WallpaperIdentity: Equatable, Sendable {
    case file(URL)
    case photosAsset(String)

    var stableIdentifier: String {
        switch self {
        case .file(let url):
            return "file:\(url.standardizedFileURL.absoluteString)"
        case .photosAsset(let identifier):
            return "photos:\(identifier)"
        }
    }

    var fileURL: URL? {
        guard case .file(let url) = self else { return nil }
        return url
    }

    init?(stableIdentifier: String) {
        if stableIdentifier.hasPrefix("file:"),
           let url = URL(string: String(stableIdentifier.dropFirst("file:".count))) {
            self = .file(url)
        } else if stableIdentifier.hasPrefix("photos:") {
            self = .photosAsset(String(stableIdentifier.dropFirst("photos:".count)))
        } else {
            return nil
        }
    }
}

struct WallpaperSource: Sendable {
    var originalURL: URL
    var renderURL: URL
    var spaceUUID: String?
    var identity: WallpaperIdentity

    init(
        originalURL: URL,
        renderURL: URL,
        spaceUUID: String?,
        identity: WallpaperIdentity? = nil
    ) {
        self.originalURL = originalURL
        self.renderURL = renderURL
        self.spaceUUID = spaceUUID
        self.identity = identity ?? .file(originalURL)
    }

    var usesPreparedRenderFile: Bool {
        originalURL.standardizedFileURL.path != renderURL.standardizedFileURL.path
    }

    func withContext(identity: WallpaperIdentity, spaceUUID: String?) -> WallpaperSource {
        WallpaperSource(
            originalURL: originalURL,
            renderURL: renderURL,
            spaceUUID: spaceUUID,
            identity: identity
        )
    }
}

enum WallpaperSourceResolution {
    case resolved(WallpaperSource)
    case blocked(String)
    /// The wallpaper is a kind WandelBar refuses to touch (video/animated wallpapers).
    /// Applying to one would silently replace it with a still frame that macOS cannot
    /// turn back into a moving wallpaper, so the desktop is left untouched instead.
    case unsupported(String)
    case unavailable

    var source: WallpaperSource? {
        if case .resolved(let source) = self {
            return source
        }

        return nil
    }

    var url: URL? {
        source?.originalURL
    }
}

struct WallpaperStoreResolver {
    private let fileManager = FileManager.default
    private let photosExporter = PhotosAssetExporter()
    private let imageFilePreparer = QuickLookImageFilePreparer()
    private let activeSpaceResolver = ActiveSpaceResolver()

    private var indexURL: URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.wallpaper/Store/Index.plist", isDirectory: false)
    }

    func wallpaperSource(for display: DisplaySnapshot) -> WallpaperSourceResolution {
        let reference: WallpaperReference
        switch wallpaperReference(for: display) {
        case .reference(let resolved):
            reference = resolved
        case .unsupported(let reason):
            return .unsupported(reason)
        case .none:
            return .unavailable
        }

        let resolution: WallpaperSourceResolution
        switch reference.identity {
        case .file(let url):
            resolution = imageFilePreparer.prepare(url, display: display)
        case .photosAsset(let identifier):
            resolution = photosExporter.exportAsset(identifier: identifier)
        }

        switch resolution {
        case .resolved(let source):
            return .resolved(
                source.withContext(identity: reference.identity, spaceUUID: reference.spaceUUID)
            )
        case .blocked, .unsupported, .unavailable:
            return resolution
        }
    }

    /// Reads only the wallpaper store metadata. It never invokes QuickLook, Photos, a
    /// subprocess, or a blocking wait, so it is safe to call from the main actor.
    func wallpaperIdentity(for display: DisplaySnapshot) -> WallpaperIdentity? {
        guard case .reference(let reference) = wallpaperReference(for: display) else {
            return nil
        }
        return reference.identity
    }

    /// Store-only support check with the same guarantees as `wallpaperIdentity(for:)`:
    /// no QuickLook, Photos, subprocess, or blocking wait, so the popover can ask for it
    /// while it is being shown.
    func unsupportedReason(for display: DisplaySnapshot) -> String? {
        guard case .unsupported(let reason) = wallpaperReference(for: display) else {
            return nil
        }
        return reason
    }

    func activeSpaceUUID(for display: DisplaySnapshot) -> String? {
        activeSpaceContext(for: display)?.activeSpaceUUID
    }

    func activeSpaceContext(for display: DisplaySnapshot) -> ActiveSpaceContext? {
        activeSpaceResolver.spaceContext(forDisplayUUID: display.uuid)
    }

    func preparedSource(originalURL: URL, for display: DisplaySnapshot) -> WallpaperSourceResolution {
        if Self.isDynamicWallpaperPlaceholder(originalURL) {
            return .unsupported(Self.videoWallpaperReason)
        }

        if !WallpaperFileValidator.isReadableRegularFile(originalURL, fileManager: fileManager),
           let identifier = Self.legacyPhotosAssetIdentifier(
               in: originalURL,
               photosCacheDirectory: photosCacheDirectory
           ) {
            return photosExporter.exportAsset(identifier: identifier)
        }

        return imageFilePreparer.prepare(originalURL, display: display)
    }

    private var photosCacheDirectory: URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WandelBar/Originals/Photos", isDirectory: true)
    }

    static func legacyPhotosAssetIdentifier(
        in sourceURL: URL,
        photosCacheDirectory: URL
    ) -> String? {
        guard sourceURL.isFileURL,
              sourceURL.deletingLastPathComponent().standardizedFileURL.path
                == photosCacheDirectory.standardizedFileURL.path else {
            return nil
        }

        let identifier = sourceURL.deletingPathExtension().lastPathComponent
        return UUID(uuidString: identifier) == nil ? nil : identifier
    }

    private func loadIndex() -> [String: Any]? {
        guard let data = try? Data(contentsOf: indexURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }

        return plist as? [String: Any]
    }

    func desktopCandidates(
        from root: [String: Any],
        displayUUID: String?,
        activeSpaceUUID: String?
    ) -> [DesktopCandidate] {
        var candidates: [DesktopCandidate] = []
        let spaces = root["Spaces"] as? [String: Any]

        if let activeSpaceUUID {
            guard let activeSpace = spaces?[activeSpaceUUID] as? [String: Any] else {
                // SkyLight can expose a newly-created Space before the wallpaper store has
                // written its entry. Display/SystemDefault may still describe a different
                // Space, so let the controller use the wallpaper currently visible through
                // NSWorkspace instead of borrowing that stale fallback.
                return []
            }

            appendSpaceCandidates(
                from: activeSpace,
                displayUUID: displayUUID,
                spaceUUID: activeSpaceUUID,
                displayPriority: 100,
                defaultPriority: 90,
                to: &candidates
            )

            // Once the active Space is known, only its own entries are trustworthy. If its
            // entry is incomplete, an empty result intentionally falls back to NSWorkspace.
            return candidates.sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }
                return lhs.lastUseOrSet > rhs.lastUseOrSet
            }
        }

        // Never use another Space as a fallback. If the active Space cannot be resolved or
        // its wallpaper is unsupported, borrowing a recently used wallpaper from elsewhere
        // is worse than falling back to NSWorkspace in the controller.

        if let displayUUID,
           let displays = root["Displays"] as? [String: Any],
           let display = displays[displayUUID] as? [String: Any],
           let desktop = display["Desktop"] as? [String: Any] {
            candidates.append(DesktopCandidate(desktop: desktop, priority: 20, spaceUUID: nil))
        }

        if let systemDefault = root["SystemDefault"] as? [String: Any],
           let desktop = systemDefault["Desktop"] as? [String: Any] {
            candidates.append(DesktopCandidate(desktop: desktop, priority: 10, spaceUUID: nil))
        }

        return candidates.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }

            return lhs.lastUseOrSet > rhs.lastUseOrSet
        }
    }

    private func appendSpaceCandidates(
        from space: [String: Any],
        displayUUID: String?,
        spaceUUID: String,
        displayPriority: Int,
        defaultPriority: Int,
        to candidates: inout [DesktopCandidate]
    ) {
        if let displayUUID,
           let displays = space["Displays"] as? [String: Any],
           let display = displays[displayUUID] as? [String: Any],
           let desktop = display["Desktop"] as? [String: Any] {
            candidates.append(
                DesktopCandidate(
                    desktop: desktop,
                    priority: displayPriority,
                    spaceUUID: spaceUUID
                )
            )
        }

        if let defaultConfiguration = space["Default"] as? [String: Any],
           let desktop = defaultConfiguration["Desktop"] as? [String: Any] {
            candidates.append(
                DesktopCandidate(
                    desktop: desktop,
                    priority: defaultPriority,
                    spaceUUID: spaceUUID
                )
            )
        }
    }

    private func wallpaperReference(for display: DisplaySnapshot) -> WallpaperReferenceResolution {
        guard let root = loadIndex() else { return .none }

        let displayUUID = display.uuid
        let spaceContext = activeSpaceResolver.spaceContext(forDisplayUUID: displayUUID)
        let candidates = desktopCandidates(
            from: root,
            displayUUID: displayUUID,
            activeSpaceUUID: spaceContext?.wallpaperSpaceUUID
        )

        for candidate in candidates {
            guard let identity = wallpaperIdentity(fromDesktop: candidate.desktop) else {
                if let reason = Self.unsupportedWallpaperReason(fromDesktop: candidate.desktop) {
                    return .unsupported(reason)
                }
                continue
            }

            if let url = identity.fileURL, Self.isDynamicWallpaperPlaceholder(url) {
                return .unsupported(Self.videoWallpaperReason)
            }

            // A fullscreen Space has no wallpaper of its own. Read the first desktop
            // Space's wallpaper, but keep state scoped to the active fullscreen Space.
            return .reference(
                WallpaperReference(
                    identity: identity,
                    spaceUUID: spaceContext?.activeSpaceUUID ?? candidate.spaceUUID
                )
            )
        }

        return .none
    }

    /// Providers that describe a moving wallpaper rather than an image file. They expose no
    /// readable still on disk that macOS would accept back, so they are reported instead of
    /// being flattened into a frame.
    static func unsupportedWallpaperReason(fromDesktop desktop: [String: Any]) -> String? {
        guard let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]] else {
            return nil
        }

        for choice in choices {
            guard let provider = choice["Provider"] as? String,
                  let reason = unsupportedProviderReason(provider) else {
                continue
            }

            return reason
        }

        return nil
    }

    static let videoWallpaperReason = "video wallpapers are not supported"

    /// macOS never exposes a video wallpaper as a file. Both the wallpaper store and
    /// `NSWorkspace.desktopImageURL` report a placeholder still instead:
    /// `/System/Library/CoreServices/DefaultDesktop.heic`, a symlink to
    /// `/System/Library/Wallpapers/.default/DefaultAerial.heic`. Treating that frame as the
    /// wallpaper is what silently froze the moving wallpaper on the lock screen.
    static func isDynamicWallpaperPlaceholder(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }

        let paths = [
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().standardizedFileURL.path
        ]

        return paths.contains { path in
            path == "/System/Library/CoreServices/DefaultDesktop.heic"
                || path.hasPrefix("/System/Library/Wallpapers/")
        }
    }

    static func unsupportedProviderReason(_ provider: String) -> String? {
        switch provider {
        case "com.apple.wallpaper.choice.aerials",
             "com.apple.NeptuneOneExtension":
            return videoWallpaperReason
        case "com.apple.wallpaper.choice.macintosh":
            return "animated wallpapers are not supported"
        default:
            return nil
        }
    }

    func wallpaperIdentity(fromDesktop desktop: [String: Any]) -> WallpaperIdentity? {
        guard let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]] else {
            return nil
        }

        for choice in choices {
            if let identity = wallpaperIdentity(fromChoice: choice) {
                return identity
            }
        }

        return nil
    }

    private func wallpaperIdentity(fromChoice choice: [String: Any]) -> WallpaperIdentity? {
        if let files = choice["Files"] as? [[String: Any]] {
            for file in files {
                if let url = firstImageFileURL(in: file) {
                    return .file(url)
                }
            }
        }

        guard let configurationData = choice["Configuration"] as? Data,
              !configurationData.isEmpty,
              let configuration = try? PropertyListSerialization.propertyList(
                from: configurationData,
                options: [],
                format: nil
              ) else {
            return nil
        }

        if let url = firstImageFileURL(in: configuration) {
            return .file(url)
        }

        if isPhotosChoice(choice: choice, configuration: configuration),
           let identifier = photosAssetIdentifier(in: configuration) {
            return .photosAsset(identifier)
        }

        return nil
    }

    private func firstImageFileURL(in object: Any) -> URL? {
        if let string = object as? String {
            return imageFileURL(from: string)
        }

        if let values = object as? [Any] {
            for value in values {
                if let url = firstImageFileURL(in: value) {
                    return url
                }
            }

            return nil
        }

        guard let dictionary = object as? [String: Any] else {
            return nil
        }

        for key in ["relative", "absolute", "file", "fileURL", "path"] {
            if let string = dictionary[key] as? String,
               let url = imageFileURL(from: string) {
                return url
            }
        }

        if let urlValue = dictionary["url"],
           let url = firstImageFileURL(in: urlValue) {
            return url
        }

        for value in dictionary.values {
            if let url = firstImageFileURL(in: value) {
                return url
            }
        }

        return nil
    }

    private func imageFileURL(from string: String) -> URL? {
        let url: URL?

        if string.hasPrefix("file://") {
            url = URL(string: string)
        } else if string.hasPrefix("/") {
            url = URL(fileURLWithPath: string)
        } else {
            url = nil
        }

        guard let url,
              url.isFileURL,
              isSupportedImageExtension(url.pathExtension) else {
            return nil
        }

        return url
    }

    private func isSupportedImageExtension(_ pathExtension: String) -> Bool {
        switch pathExtension.lowercased() {
        case "avif", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp":
            return true
        default:
            return false
        }
    }

    private func isPhotosChoice(choice: [String: Any], configuration: Any) -> Bool {
        if let provider = choice["Provider"] as? String,
           provider == "com.apple.wallpaper.extension.photos" {
            return true
        }

        if let dictionary = configuration as? [String: Any],
           dictionary["type"] as? String == "asset",
           dictionary["identifier"] as? String != nil {
            return true
        }

        return false
    }

    private func photosAssetIdentifier(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            if let identifier = dictionary["identifier"] as? String {
                return identifier
            }

            for value in dictionary.values {
                if let identifier = photosAssetIdentifier(in: value) {
                    return identifier
                }
            }
        }

        if let values = object as? [Any] {
            for value in values {
                if let identifier = photosAssetIdentifier(in: value) {
                    return identifier
                }
            }
        }

        return nil
    }
}

enum WallpaperReferenceResolution {
    case reference(WallpaperReference)
    case unsupported(String)
    case none
}

struct DesktopCandidate {
    var desktop: [String: Any]
    var priority: Int
    var spaceUUID: String?

    var lastUseOrSet: Date {
        if let lastUse = desktop["LastUse"] as? Date {
            return lastUse
        }

        if let lastSet = desktop["LastSet"] as? Date {
            return lastSet
        }

        return .distantPast
    }
}

struct WallpaperReference {
    var identity: WallpaperIdentity
    var spaceUUID: String?
}

struct ActiveSpaceContext: Equatable {
    var activeSpaceUUID: String
    var wallpaperSpaceUUID: String
    var isFullscreen: Bool
}

struct ActiveSpaceResolver {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private struct Symbols: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer
        let mainConnectionID: MainConnectionID
        let copyManagedDisplaySpaces: CopyManagedDisplaySpaces
    }

    /// Keep the framework open for the process lifetime and resolve symbols once. Repeated
    /// `dlopen` calls increment the loader reference count and are unnecessary here.
    private static let symbols: Symbols? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ), let mainConnectionSymbol = dlsym(handle, "CGSMainConnectionID"),
           let copySpacesSymbol = dlsym(handle, "CGSCopyManagedDisplaySpaces") else {
            return nil
        }

        return Symbols(
            handle: handle,
            mainConnectionID: unsafeBitCast(mainConnectionSymbol, to: MainConnectionID.self),
            copyManagedDisplaySpaces: unsafeBitCast(
                copySpacesSymbol,
                to: CopyManagedDisplaySpaces.self
            )
        )
    }()

    func spaceContext(forDisplayUUID displayUUID: String?) -> ActiveSpaceContext? {
        guard let displayUUID, let symbols = Self.symbols else {
            return nil
        }

        guard let unmanagedSpaces = symbols.copyManagedDisplaySpaces(symbols.mainConnectionID()) else {
            return nil
        }

        let spaces = unmanagedSpaces.takeRetainedValue() as NSArray

        for item in spaces {
            guard let display = item as? [String: Any],
                  display["Display Identifier"] as? String == displayUUID else {
                continue
            }

            return Self.spaceContext(fromManagedDisplay: display)
        }

        return nil
    }

    static func spaceContext(fromManagedDisplay display: [String: Any]) -> ActiveSpaceContext? {
        guard let currentSpace = display["Current Space"] as? [String: Any],
              let activeSpaceUUID = currentSpace["uuid"] as? String else {
            return nil
        }

        guard numericSpaceType(in: currentSpace) == 4,
              let spaces = display["Spaces"] as? [[String: Any]],
              let firstDesktopUUID = spaces.first(where: {
                  numericSpaceType(in: $0) == 0 && $0["uuid"] as? String != nil
              })?["uuid"] as? String else {
            return ActiveSpaceContext(
                activeSpaceUUID: activeSpaceUUID,
                wallpaperSpaceUUID: activeSpaceUUID,
                isFullscreen: false
            )
        }

        return ActiveSpaceContext(
            activeSpaceUUID: activeSpaceUUID,
            wallpaperSpaceUUID: firstDesktopUUID,
            isFullscreen: true
        )
    }

    private static func numericSpaceType(in space: [String: Any]) -> Int? {
        if let number = space["type"] as? NSNumber {
            return number.intValue
        }

        return space["type"] as? Int
    }
}

private struct QuickLookImageFilePreparer {
    private let fileManager = FileManager.default

    private var outputDirectory: URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WandelBar/Originals/QuickLook", isDirectory: true)
    }

    func prepare(_ sourceURL: URL, display: DisplaySnapshot) -> WallpaperSourceResolution {
        if canReadDirectly(sourceURL) {
            return .resolved(
                WallpaperSource(
                    originalURL: sourceURL,
                    renderURL: sourceURL,
                    spaceUUID: nil
                )
            )
        }

        let outputURL = preparedImageURL(for: sourceURL, display: display)

        if fileManager.fileExists(atPath: outputURL.path) {
            return .resolved(
                WallpaperSource(
                    originalURL: sourceURL,
                    renderURL: outputURL,
                    spaceUUID: nil
                )
            )
        }

        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            return .blocked("QuickLook cache could not be created: \(error.localizedDescription)")
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: sourceURL,
            size: display.pixelSize,
            scale: 1,
            representationTypes: .thumbnail
        )
        let semaphore = DispatchSemaphore(value: 0)
        let box = ThumbnailBox()

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
            box.set(thumbnail: thumbnail, error: error)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 30) == .success else {
            return .blocked("QuickLook timed out while rendering the wallpaper source")
        }

        let snapshot = box.snapshot
        guard let thumbnail = snapshot.thumbnail else {
            if let data = qlmanageThumbnailData(for: sourceURL, display: display) {
                do {
                    try data.write(to: outputURL, options: .atomic)
                    return .resolved(
                        WallpaperSource(
                            originalURL: sourceURL,
                            renderURL: outputURL,
                            spaceUUID: nil
                        )
                    )
                } catch {
                    return .blocked("QuickLook wallpaper cache write failed: \(error.localizedDescription)")
                }
            }

            let message = snapshot.error?.localizedDescription ?? "thumbnail unavailable"
            return .blocked("QuickLook could not render wallpaper source: \(message)")
        }

        guard let data = pngData(from: thumbnail.nsImage) else {
            return .blocked("QuickLook wallpaper source could not be encoded")
        }

        do {
            try data.write(to: outputURL, options: .atomic)
            return .resolved(
                WallpaperSource(
                    originalURL: sourceURL,
                    renderURL: outputURL,
                    spaceUUID: nil
                )
            )
        } catch {
            return .blocked("QuickLook wallpaper cache write failed: \(error.localizedDescription)")
        }
    }

    private func qlmanageThumbnailData(
        for sourceURL: URL,
        display: DisplaySnapshot
    ) -> Data? {
        let temporaryDirectory = outputDirectory
            .appendingPathComponent("Transient", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = [
            "-t",
            "-s",
            "\(Int(max(display.pixelSize.width, display.pixelSize.height)))",
            "-o",
            temporaryDirectory.path,
            sourceURL.path
        ]

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        guard termination.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0,
              let generatedURL = generatedQuickLookThumbnail(in: temporaryDirectory),
              let data = try? Data(contentsOf: generatedURL) else {
            return nil
        }

        return data
    }

    private func generatedQuickLookThumbnail(in directory: URL) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else {
            return nil
        }

        return contents
            .filter { url in
                guard let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
                    return false
                }

                return resourceValues.isRegularFile == true
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))
                    .flatMap(\.contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))
                    .flatMap(\.contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .first
    }

    private func canReadDirectly(_ url: URL) -> Bool {
        guard WallpaperFileValidator.isReadableRegularFile(url, fileManager: fileManager) else {
            return false
        }

        let path = url.standardizedFileURL.path
        let appSupportPath = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WandelBar", isDirectory: true)
            .standardizedFileURL
            .path

        if path == appSupportPath || path.hasPrefix(appSupportPath + "/") {
            return true
        }

        return path.hasPrefix("/System/")
            || path.hasPrefix("/Library/Desktop Pictures/")
            || path.hasPrefix("/Library/Application Support/")
    }

    private func preparedImageURL(for sourceURL: URL, display: DisplaySnapshot) -> URL {
        let filename = FileCacheKey.sourceSignature(
            for: sourceURL,
            pixelSize: display.pixelSize
        ) + ".png"
        return outputDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}

private final class ThumbnailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var thumbnail: QLThumbnailRepresentation?
    private var error: Error?

    var snapshot: (thumbnail: QLThumbnailRepresentation?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (thumbnail, error)
    }

    func set(thumbnail: QLThumbnailRepresentation?, error: Error?) {
        lock.lock()
        self.thumbnail = thumbnail
        self.error = error
        lock.unlock()
    }
}

private struct PhotosAssetExporter {
    private let fileManager = FileManager.default

    private var outputDirectory: URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WandelBar/Originals/Photos", isDirectory: true)
    }

    func exportAsset(identifier: String) -> WallpaperSourceResolution {
        guard ensurePhotosAccess() else {
            return .blocked("Photos access is required to use the current wallpaper")
        }

        guard let asset = fetchAsset(identifier: identifier) else {
            return .blocked("Photos wallpaper asset was not found")
        }

        let cacheName = FileCacheKey.digest([
            identifier,
            asset.modificationDate?.timeIntervalSince1970.description ?? "unknown-date"
        ])

        if let cachedURL = cachedExport(named: cacheName) {
            return .resolved(
                WallpaperSource(
                    originalURL: cachedURL,
                    renderURL: cachedURL,
                    spaceUUID: nil,
                    identity: .photosAsset(identifier)
                )
            )
        }

        guard let exported = requestImageData(for: asset) else {
            return .blocked("Photos wallpaper asset could not be exported")
        }

        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

            let outputURL = outputDirectory
                .appendingPathComponent(cacheName, isDirectory: false)
                .appendingPathExtension(exported.filenameExtension)

            try exported.data.write(to: outputURL, options: .atomic)
            return .resolved(
                WallpaperSource(
                    originalURL: outputURL,
                    renderURL: outputURL,
                    spaceUUID: nil,
                    identity: .photosAsset(identifier)
                )
            )
        } catch {
            return .blocked("Photos wallpaper export failed: \(error.localizedDescription)")
        }
    }

    private func cachedExport(named cacheName: String) -> URL? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return nil
        }

        return files.first { url in
            guard url.deletingPathExtension().lastPathComponent == cacheName,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
                return false
            }
            return values.isRegularFile == true
        }
    }

    private func ensurePhotosAccess() -> Bool {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        switch currentStatus {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let box = AuthorizationStatusBox()
            let semaphore = DispatchSemaphore(value: 0)

            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                box.setStatus(status)
                semaphore.signal()
            }

            guard semaphore.wait(timeout: .now() + 120) == .success else {
                return false
            }
            return box.hasAccess
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func fetchAsset(identifier: String) -> PHAsset? {
        let directFetch = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)

        if let asset = directFetch.firstObject {
            return asset
        }

        let options = PHFetchOptions()
        options.includeHiddenAssets = true

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var matchedAsset: PHAsset?

        assets.enumerateObjects { asset, _, stop in
            if asset.localIdentifier.contains(identifier) {
                matchedAsset = asset
                stop.pointee = true
            }
        }

        return matchedAsset
    }

    private func requestImageData(for asset: PHAsset) -> ExportedPhotoData? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        options.version = .current

        let box = ImageDataBox()
        let semaphore = DispatchSemaphore(value: 0)
        let manager = PHImageManager.default()

        let requestID = manager.requestImageDataAndOrientation(
            for: asset,
            options: options
        ) { data, dataUTI, _, info in
            let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue == true
            let error = info?[PHImageErrorKey] as? Error
            box.set(data: data, dataUTI: dataUTI, error: error, cancelled: cancelled)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 120) == .success else {
            manager.cancelImageRequest(requestID)
            return nil
        }

        let snapshot = box.snapshot
        guard !snapshot.cancelled, snapshot.error == nil, let data = snapshot.data else {
            return nil
        }

        let filenameExtension: String

        if let dataUTI = snapshot.dataUTI,
           let preferredExtension = UTType(dataUTI)?.preferredFilenameExtension {
            filenameExtension = preferredExtension
        } else {
            filenameExtension = "jpg"
        }

        return ExportedPhotoData(data: data, filenameExtension: filenameExtension)
    }
}

private final class AuthorizationStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: PHAuthorizationStatus = .notDetermined

    var hasAccess: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status == .authorized || status == .limited
    }

    func setStatus(_ status: PHAuthorizationStatus) {
        lock.lock()
        self.status = status
        lock.unlock()
    }
}

private final class ImageDataBox: @unchecked Sendable {
    struct Snapshot {
        var data: Data?
        var dataUTI: String?
        var error: Error?
        var cancelled: Bool
    }

    private let lock = NSLock()
    private var value = Snapshot(data: nil, dataUTI: nil, error: nil, cancelled: false)

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(data: Data?, dataUTI: String?, error: Error?, cancelled: Bool) {
        lock.lock()
        value = Snapshot(data: data, dataUTI: dataUTI, error: error, cancelled: cancelled)
        lock.unlock()
    }
}

private struct ExportedPhotoData {
    var data: Data
    var filenameExtension: String
}
