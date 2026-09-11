import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum PresetSharingError: LocalizedError {
    case attachmentTooLarge(String, Int)
    case wallpaperUnavailable
    var errorDescription: String? {
        switch self {
        case .wallpaperUnavailable:
            "Current wallpaper could not be read. Choose Sample Background or try again with a static wallpaper."
        case let .attachmentTooLarge(name, megabytes):
            "\(name) exceeds GitHub’s \(megabytes) MB attachment limit. Share fewer presets or use smaller custom textures."
        }
    }
}

struct PresetShareResult: Sendable {
    let directory: URL
    let previewURLs: [URL]
    let markdown: String
    var title: String = "My WandelBar presets"
    var usesCurrentWallpaper = false

    // GitHub can append upload Markdown without a blank line. Put the download
    // first so it cannot become literal text immediately after an image block.
    var attachmentURLs: [URL] { [directory.appendingPathComponent("Presets.zip")] + previewURLs }
}

@MainActor
final class PresetSharingService {
    private let packages: any PresetPackageServicing
    private let textures: TextureAssetStore

    init(packages: any PresetPackageServicing = PresetPackageService.shared, textures: TextureAssetStore = .shared) {
        self.packages = packages
        self.textures = textures
    }

    func prepare(presets: [EffectPreset], in parent: URL = FileManager.default.temporaryDirectory, wallpaper: PresetPreviewContext? = nil) async throws -> PresetShareResult {
        guard !presets.isEmpty else { throw PresetPackageError.noPresetsSelected }
        let directory = parent.appendingPathComponent("WandelBar Share \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let contents = directory.appendingPathComponent(".package", isDirectory: true)
        let backgroundSnapshot = directory.appendingPathComponent(".preview-source")
        var completed = false
        defer {
            try? FileManager.default.removeItem(at: contents)
            try? FileManager.default.removeItem(at: backgroundSnapshot)
            if !completed { try? FileManager.default.removeItem(at: directory) }
        }
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        _ = try await packages.export(presetIDs: presets.map(\.id), to: contents.appendingPathComponent("Presets.wandelbar-presets"))
        try Task.checkCancellation()
        let items = presets.map {
            SharePreviewItem(name: $0.name, settings: $0.settings, textureURL: textures.resolvedURL(for: $0.settings.textureID))
        }
        let work = Task.detached(priority: .userInitiated) {
            var renderWallpaper: PresetPreviewContext?
            if let wallpaper {
                try Task.checkCancellation()
                let values = try wallpaper.sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 100_000_000 else {
                    throw PresetSharingError.wallpaperUnavailable
                }
                try FileManager.default.copyItem(at: wallpaper.sourceURL, to: backgroundSnapshot)
                renderWallpaper = PresetPreviewContext(sourceURL: backgroundSnapshot, display: wallpaper.display,
                    storedDesktop: wallpaper.storedDesktop, sourceIdentity: wallpaper.sourceIdentity)
            }
            var previews: [URL] = []
            for offset in stride(from: 0, to: items.count, by: 6) {
                try Task.checkCancellation()
                let slice = Array(items[offset..<min(offset + 6, items.count)])
                let image = try SharePreviewRenderer.render(slice, wallpaper: renderWallpaper)
                let url = directory.appendingPathComponent("Preview-\(previews.count + 1).png")
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw PresetPackageError.persistenceFailed
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw PresetPackageError.persistenceFailed }
                try Self.validateAttachment(url, limitMB: 10)
                previews.append(url)
            }
            try Self.wrapForGitHub(contents, at: directory.appendingPathComponent("Presets.zip"))
            try Self.validateAttachment(directory.appendingPathComponent("Presets.zip"), limitMB: 25)
            return previews
        }
        let previews = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        let text = Self.markdown(names: presets.map(\.name), previewNames: previews.map(\.lastPathComponent), usesCurrentWallpaper: wallpaper != nil)
        try text.write(to: directory.appendingPathComponent("Post.md"), atomically: true, encoding: .utf8)
        completed = true
        return PresetShareResult(directory: directory, previewURLs: previews, markdown: text, title: presets.count == 1 ? String(presets[0].name.prefix(100)) : "My WandelBar presets (\(presets.count))", usesCurrentWallpaper: wallpaper != nil)
    }

    nonisolated static func validateAttachment(_ url: URL, limitMB: Int) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= limitMB * 1_000_000 else {
            throw PresetSharingError.attachmentTooLarge(url.lastPathComponent, limitMB)
        }
    }

    nonisolated static func markdown(names: [String], previewNames: [String], usesCurrentWallpaper: Bool = false) -> String {
        let background = usesCurrentWallpaper
            ? "_Previews use my current wallpaper, included in the preview images only._"
            : "_Previews use WandelBar's standard sample background, not my desktop wallpaper._"
        let names = names.map { "- **\(escapeMarkdown($0))**" }.joined(separator: "\n")
        return """
        ## WandelBar preset pack

        \(names)

        \(background)
        _The package contains effect settings and custom textures; it does not include wallpaper images._

        1. Download and unzip Presets.zip;
        2. Import Presets.wandelbar-presets in WandelBar;
        3. Review and select presets before importing.

        Official app: https://github.com/alexiosus/WandelBar

        ## Previews and download
        """
    }

    nonisolated private static func escapeMarkdown(_ value: String) -> String {
        let flattened = value.components(separatedBy: .controlCharacters).joined(separator: " ")
        return String(flattened.prefix(160)).reduce(into: "") { output, char in
            if "\\`*_{}[]<>()#+-.!|".contains(char) { output.append("\\") }
            output.append(char)
        }
    }

    nonisolated private static func wrapForGitHub(_ contents: URL, at destination: URL) throws {
        try SystemPresetPackageArchive().createSharingArchive(
            from: contents, at: destination, allowedFileNames: ["Presets.wandelbar-presets"])
    }
}
