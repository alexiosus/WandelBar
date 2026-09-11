import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PresetPackageExportSummary: Equatable, Sendable {
    let presetCount: Int
    let textureCount: Int
}

struct PresetPackageImportResult: Equatable, Sendable {
    let presetCount: Int
    let newTextureCount: Int
}

enum PresetPackageError: LocalizedError, Equatable {
    case noPresetsSelected
    case presetNotFound
    case builtInPresetSelected
    case sourceTextureMissing(String)
    case unsupportedVersion
    case malformedPackage
    case unsafeArchive
    case limitsExceeded
    case textureMissing(String)
    case textureCorrupted(String)
    case catalogChanged
    case previewExpired
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .noPresetsSelected: "Select at least one preset."
        case .presetNotFound: "A selected preset no longer exists."
        case .builtInPresetSelected: "Built-in presets cannot be exported."
        case .sourceTextureMissing: "A custom texture used by this preset is missing."
        case .unsupportedVersion: "This preset package was created by an unsupported version of WandelBar."
        case .malformedPackage: "The preset package is damaged or incomplete."
        case .unsafeArchive: "The preset package contains unsafe files."
        case .limitsExceeded: "The preset package is too large."
        case .textureMissing: "A texture required by this preset package is missing."
        case .textureCorrupted: "A texture in this preset package is damaged."
        case .catalogChanged: "Your presets changed after the preview. Please open the package again."
        case .previewExpired: "This import preview has expired."
        case .persistenceFailed: "The preset package could not be saved."
        }
    }
}

final class PresetPackageImportToken: @unchecked Sendable {
    let id: UUID
    private let cleanup: @Sendable (UUID) -> Void

    init(id: UUID = UUID(), cleanup: @escaping @Sendable (UUID) -> Void = { _ in }) {
        self.id = id
        self.cleanup = cleanup
    }

    deinit { cleanup(id) }
}

struct PresetPackageImportPreview: Identifiable, Sendable {
    struct Preset: Equatable, Identifiable, Sendable {
        let id: String
        let sourceName: String
        let finalName: String
        let wasRenamed: Bool
        let settings: WallpaperEffectSettings
        let previewPNG: Data?
        init(id: String, sourceName: String, finalName: String, wasRenamed: Bool,
             settings: WallpaperEffectSettings = .default, previewPNG: Data? = nil) {
            self.id = id; self.sourceName = sourceName; self.finalName = finalName
            self.wasRenamed = wasRenamed; self.settings = settings; self.previewPNG = previewPNG
        }
    }

    var id: UUID { token.id }
    let presets: [Preset]
    let embeddedTextureCount: Int
    let token: PresetPackageImportToken
}

@MainActor
protocol PresetPackageServicing: AnyObject {
    func export(presetIDs: [String], to destinationURL: URL) async throws -> PresetPackageExportSummary
    func prepareImport(from packageURL: URL) async throws -> PresetPackageImportPreview
    func discardImport(_ preview: PresetPackageImportPreview)
    func commitImport(_ preview: PresetPackageImportPreview) throws -> PresetPackageImportResult
    func commitImport(_ preview: PresetPackageImportPreview, selectedIDs: Set<String>) throws -> PresetPackageImportResult
    func commitImportInBackground(_ preview: PresetPackageImportPreview, selectedIDs: Set<String>) async throws -> PresetPackageImportResult
}

extension PresetPackageServicing {
    func commitImportInBackground(_ preview: PresetPackageImportPreview, selectedIDs: Set<String>) async throws -> PresetPackageImportResult {
        try Task.checkCancellation()
        return try commitImport(preview, selectedIDs: selectedIDs)
    }

    func commitImport(_ preview: PresetPackageImportPreview, selectedIDs: Set<String>) throws -> PresetPackageImportResult {
        guard selectedIDs == Set(preview.presets.map(\.id)) else { throw PresetPackageError.noPresetsSelected }
        return try commitImport(preview)
    }
}

@MainActor
final class PresetPackageService: PresetPackageServicing {
    static let shared = PresetPackageService()

    private final class ImportSession {
        let id: UUID
        let tokenIdentity: ObjectIdentifier
        let extractionDirectory: URL
        let manifest: PresetPackageManifest
        let finalNames: [String]
        let embeddedPayloads: [PackageTexturePayload]
        let presetCatalog: [String]

        init(
            id: UUID,
            tokenIdentity: ObjectIdentifier,
            extractionDirectory: URL,
            manifest: PresetPackageManifest,
            finalNames: [String],
            embeddedPayloads: [PackageTexturePayload],
            presetCatalog: [String]
        ) {
            self.id = id
            self.tokenIdentity = tokenIdentity
            self.extractionDirectory = extractionDirectory
            self.manifest = manifest
            self.finalNames = finalNames
            self.embeddedPayloads = embeddedPayloads
            self.presetCatalog = presetCatalog
        }
    }

    private let presetStore: EffectPresetStore
    private let textureStore: TextureAssetStore
    private let archive: any PresetPackageArchiving
    private let limits: PresetPackageLimits
    private let fileManager: FileManager
    private var sessions: [UUID: ImportSession] = [:]

    init(
        presetStore: EffectPresetStore = .shared,
        textureStore: TextureAssetStore = .shared,
        archive: any PresetPackageArchiving = SystemPresetPackageArchive(),
        limits: PresetPackageLimits = .default,
        fileManager: FileManager = .default
    ) {
        self.presetStore = presetStore
        self.textureStore = textureStore
        self.archive = archive is SystemPresetPackageArchive ? SystemPresetPackageArchive(limits: limits) : archive
        self.limits = limits
        self.fileManager = fileManager
    }

    func export(
        presetIDs: [String],
        to destinationURL: URL
    ) async throws -> PresetPackageExportSummary {
        let uniqueIDs = presetIDs.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !uniqueIDs.isEmpty else { throw PresetPackageError.noPresetsSelected }
        guard uniqueIDs.count <= limits.maximumPresets else { throw PresetPackageError.limitsExceeded }

        let presets = try uniqueIDs.map { id -> EffectPreset in
            guard let preset = presetStore.preset(id: id) else { throw PresetPackageError.presetNotFound }
            guard preset.kind == .user else { throw PresetPackageError.builtInPresetSelected }
            return preset
        }

        var textureURLs: [String: URL] = [:]
        for preset in presets {
            if let id = preset.settings.textureID, let url = textureStore.resolvedURL(for: id) { textureURLs[id] = url }
        }
        let snapshotURLs = textureURLs
        let availableTextureIDs = Set(presets.compactMap { $0.settings.textureID }.filter { textureStore.isAvailable(id: $0) })
        let archive = self.archive, limits = self.limits
        return try await Self.background {
            let textureURLs = snapshotURLs
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("WandelBar-Preset-Export-\(UUID().uuidString)", isDirectory: true)
            let staging = root.appendingPathComponent("contents", isDirectory: true)
            let temporaryArchive = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".wandelbar-export-\(UUID().uuidString)")
            defer {
                try? fileManager.removeItem(at: root)
                try? fileManager.removeItem(at: temporaryArchive)
            }

            do {
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
                var embedded: [String: Data] = [:]
                var manifestPresets: [PresetPackageManifest.Preset] = []

                for preset in presets {
                    try Task.checkCancellation()
                    var reference: PresetPackageTextureReference?
                    if let textureID = preset.settings.textureID {
                        guard availableTextureIDs.contains(textureID) else {
                            throw PresetPackageError.sourceTextureMissing(textureID)
                        }
                        switch TextureAsset.builtIns.contains(where: { $0.id == textureID }) {
                        case true:
                            guard availableTextureIDs.contains(textureID) else {
                                throw PresetPackageError.sourceTextureMissing(textureID)
                            }
                            reference = PresetPackageTextureReference(
                                kind: .builtIn, id: textureID, path: nil, sha256: nil
                            )
                        case false:
                            guard let url = textureURLs[textureID] else {
                                throw PresetPackageError.sourceTextureMissing(textureID)
                            }
                            guard try Self.fileSize(at: url) <= limits.maximumExtractedBytes else { throw PresetPackageError.limitsExceeded }
                            guard let data = try? Data(contentsOf: url) else {
                                throw PresetPackageError.sourceTextureMissing(textureID)
                            }
                            let digest = Self.sha256(data)
                            guard textureID == "custom.\(digest)",
                                  (try? TextureAssetStore.normalizeTextureData(data)) == data else {
                                throw PresetPackageError.sourceTextureMissing(textureID)
                            }
                            embedded[digest] = data
                            guard embedded.count <= limits.maximumTextures,
                                  embedded.values.reduce(Int64(0), { $0 + Int64($1.count) }) <= limits.maximumExtractedBytes else { throw PresetPackageError.limitsExceeded }
                            reference = PresetPackageTextureReference(
                                kind: .embedded,
                                id: textureID,
                                path: "textures/\(digest).png",
                                sha256: digest
                            )
                        }
                    }
                    manifestPresets.append(PresetPackageManifest.Preset(
                        sourceID: preset.id,
                        name: preset.name,
                        settings: preset.settings,
                        texture: reference
                    ))
                }

                guard embedded.count <= limits.maximumTextures else {
                    throw PresetPackageError.limitsExceeded
                }
                if !embedded.isEmpty {
                    let textures = staging.appendingPathComponent("textures", isDirectory: true)
                    try fileManager.createDirectory(at: textures, withIntermediateDirectories: true)
                    for (digest, data) in embedded {
                        try data.write(to: textures.appendingPathComponent("\(digest).png"), options: .atomic)
                    }
                }

                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "development"
                let manifest = PresetPackageManifest(createdBy: version, presets: manifestPresets)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try Self.validateStrings(manifest, limits: limits)
                let manifestData = try encoder.encode(manifest)
                guard manifestData.count <= limits.maximumManifestBytes,
                      embedded.values.reduce(Int64(manifestData.count), { $0 + Int64($1.count) }) <= limits.maximumExtractedBytes else {
                    throw PresetPackageError.limitsExceeded
                }
                try manifestData.write(
                    to: staging.appendingPathComponent("manifest.json"),
                    options: .atomic
                )
                try archive.createArchive(from: staging, at: temporaryArchive)

                try Task.checkCancellation()
                guard try Self.fileSize(at: temporaryArchive) <= limits.maximumCompressedBytes else { throw PresetPackageError.limitsExceeded }
                if fileManager.fileExists(atPath: destinationURL.path) {
                    _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryArchive)
                } else {
                    try fileManager.moveItem(at: temporaryArchive, to: destinationURL)
                }
                return PresetPackageExportSummary(
                    presetCount: presets.count,
                    textureCount: embedded.count
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PresetPackageError {
                throw error
            } catch {
                throw PresetPackageError.persistenceFailed
            }
        }
    }

    func prepareImport(from packageURL: URL) async throws -> PresetPackageImportPreview {
        let builtInURLs = Dictionary(uniqueKeysWithValues: TextureAsset.builtIns.compactMap { asset -> (String, URL)? in
            textureStore.resolvedURL(for: asset.id).map { (asset.id, $0) }
        })
        let availableBuiltIns = Set(builtInURLs.keys)
        let archive = self.archive, limits = self.limits
        let (extraction, manifest, payloadsByID, previewImages) = try await Self.background {
            try Self.prepareFiles(packageURL, archive: archive, limits: limits, availableBuiltIns: availableBuiltIns, builtInURLs: builtInURLs)
        }
        do { try Task.checkCancellation() } catch { try? fileManager.removeItem(at: extraction); throw error }
        let catalog = presetStore.presets.map(\.name)
        let finalNames = PresetImportNameResolver.resolve(
            manifest.presets.map(\.name),
            against: catalog
        )
        let id = UUID()
        let token = PresetPackageImportToken(id: id) { [weak self] tokenID in
            Task { @MainActor [weak self] in self?.discardSession(id: tokenID) }
        }
        sessions[id] = ImportSession(
            id: id,
            tokenIdentity: ObjectIdentifier(token),
            extractionDirectory: extraction,
            manifest: manifest,
            finalNames: finalNames,
            embeddedPayloads: Array(payloadsByID.values),
            presetCatalog: catalog
        )
        return PresetPackageImportPreview(
            presets: zip(manifest.presets, finalNames).map { preset, finalName in
                PresetPackageImportPreview.Preset(
                    id: preset.sourceID,
                    sourceName: preset.name,
                    finalName: finalName,
                    wasRenamed: preset.name != finalName, settings: preset.settings,
                    previewPNG: previewImages[preset.sourceID]
                )
            },
            embeddedTextureCount: payloadsByID.count,
            token: token
        )
    }

    nonisolated private static func prepareFiles(_ packageURL: URL, archive: any PresetPackageArchiving,
        limits: PresetPackageLimits, availableBuiltIns: Set<String>, builtInURLs: [String: URL]) throws -> (URL, PresetPackageManifest, [String: PackageTexturePayload], [String: Data]) {
        let fileManager = FileManager.default
        let compressedSize = try fileSize(at: packageURL)
        guard compressedSize <= limits.maximumCompressedBytes else {
            throw PresetPackageError.limitsExceeded
        }

        let snapshotRoot = fileManager.temporaryDirectory.appendingPathComponent("WandelBar-Package-Snapshot-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: snapshotRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: snapshotRoot) }
        let snapshot = snapshotRoot.appendingPathComponent("package.zip")
        try boundedCopy(from: packageURL, to: snapshot, maximumBytes: limits.maximumCompressedBytes)
        let entries: [String]
        do { entries = try archive.listEntries(in: snapshot) }
        catch is CancellationError { throw CancellationError() }
        catch let error as PresetPackageError { throw error }
        catch { throw PresetPackageError.malformedPackage }
        guard !entries.isEmpty else { throw PresetPackageError.malformedPackage }
        var seen = Set<String>()
        for entry in entries {
            guard let safe = PresetPackagePath(entry), seen.insert(safe.rawValue).inserted else {
                throw PresetPackageError.unsafeArchive
            }
        }
        guard seen.contains("manifest.json") else { throw PresetPackageError.malformedPackage }
        let archivedTexturePaths = seen.filter { $0.hasPrefix("textures/") && $0.hasSuffix(".png") }
        guard archivedTexturePaths.count <= limits.maximumTextures else {
            throw PresetPackageError.limitsExceeded
        }

        let extraction = fileManager.temporaryDirectory
            .appendingPathComponent("WandelBar-Preset-Import-\(UUID().uuidString)", isDirectory: true)
        var shouldRemove = true
        defer { if shouldRemove { try? fileManager.removeItem(at: extraction) } }
        do { try archive.extractArchive(at: snapshot, to: extraction) }
        catch is CancellationError { throw CancellationError() }
        catch let error as PresetPackageError { throw error }
        catch { throw PresetPackageError.malformedPackage }

        try validateExtractedTree(at: extraction, expectedEntries: seen, limits: limits)
        guard try fileSize(at: extraction.appendingPathComponent("manifest.json")) <= limits.maximumManifestBytes else { throw PresetPackageError.limitsExceeded }
        let manifestURL = extraction.appendingPathComponent("manifest.json")
        let manifest: PresetPackageManifest
        do { manifest = try JSONDecoder().decode(PresetPackageManifest.self, from: Data(contentsOf: manifestURL)) }
        catch is CancellationError { throw CancellationError() }
        catch let error as PresetPackageError { throw error }
        catch { throw PresetPackageError.malformedPackage }
        guard manifest.format == PresetPackageManifest.formatIdentifier,
              manifest.version == PresetPackageManifest.currentVersion else {
            throw PresetPackageError.unsupportedVersion
        }
        guard !manifest.presets.isEmpty,
              manifest.presets.count <= limits.maximumPresets else {
            throw manifest.presets.isEmpty
                ? PresetPackageError.malformedPackage
                : PresetPackageError.limitsExceeded
        }

        try validateStrings(manifest, limits: limits)
        var referencedPaths = Set<String>()
        var payloadsByID: [String: PackageTexturePayload] = [:]
        var sourceIDs = Set<String>()
        for preset in manifest.presets {
            try Task.checkCancellation()
            guard !preset.sourceID.isEmpty,
                  sourceIDs.insert(preset.sourceID).inserted,
                  !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PresetPackageError.malformedPackage
            }
            guard preset.texture?.id == preset.settings.textureID else {
                throw PresetPackageError.malformedPackage
            }
            guard let texture = preset.texture else { continue }
            switch texture.kind {
            case .builtIn:
                guard texture.path == nil, texture.sha256 == nil,
                      TextureAsset.builtIns.contains(where: { $0.id == texture.id }),
                      availableBuiltIns.contains(texture.id) else {
                    throw PresetPackageError.textureMissing(texture.id)
                }
            case .embedded:
                guard let path = texture.path,
                      let digest = texture.sha256,
                      PresetPackagePath(path) != nil,
                      path == "textures/\(digest).png",
                      texture.id == "custom.\(digest)",
                      Self.isLowercaseDigest(digest),
                      seen.contains(path) else {
                    throw PresetPackageError.textureMissing(texture.id)
                }
                referencedPaths.insert(path)
                if payloadsByID[texture.id] != nil { continue }
                let data: Data
                do { data = try Data(contentsOf: extraction.appendingPathComponent(path)) }
                catch { throw PresetPackageError.textureMissing(texture.id) }
                guard Self.sha256(data) == digest,
                      (try? TextureAssetStore.normalizeTextureData(data)) == data else {
                    throw PresetPackageError.textureCorrupted(texture.id)
                }
                let payload = PackageTexturePayload(
                    sourceID: texture.id,
                    name: preset.name,
                    pngData: data,
                    sha256: digest
                )
                if let existing = payloadsByID[texture.id], existing.pngData != data {
                    throw PresetPackageError.textureCorrupted(texture.id)
                }
                payloadsByID[texture.id] = payload
            }
        }
        guard referencedPaths == Set(archivedTexturePaths) else {
            throw PresetPackageError.malformedPackage
        }

        var previewImages: [String: Data] = [:]
        let renderer = WallpaperRenderer()
        for preset in manifest.presets {
            try Task.checkCancellation()
            let textureURL = preset.texture.flatMap { texture -> URL? in
                texture.kind == .builtIn ? builtInURLs[texture.id] : texture.path.map { extraction.appendingPathComponent($0) }
            }
            let image = try renderer.renderSamplePreview(settings: preset.settings, textureURL: textureURL, size: CGSize(width: 480, height: 270))
            let data = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw PresetPackageError.persistenceFailed }
            CGImageDestinationAddImage(encoder, image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw PresetPackageError.persistenceFailed }
            previewImages[preset.sourceID] = data as Data
        }
        shouldRemove = false
        return (extraction, manifest, payloadsByID, previewImages)
    }

    func discardImport(_ preview: PresetPackageImportPreview) {
        guard let session = sessions[preview.id],
              session.tokenIdentity == ObjectIdentifier(preview.token) else { return }
        discardSession(id: preview.id)
    }

    func commitImport(_ preview: PresetPackageImportPreview) throws -> PresetPackageImportResult {
        try commitImport(preview, selectedIDs: Set(preview.presets.map(\.id)))
    }

    func commitImport(_ preview: PresetPackageImportPreview, selectedIDs: Set<String>) throws -> PresetPackageImportResult {
        guard !selectedIDs.isEmpty else { throw PresetPackageError.noPresetsSelected }
        guard let session = sessions[preview.id],
              session.tokenIdentity == ObjectIdentifier(preview.token) else {
            throw PresetPackageError.previewExpired
        }
        guard presetStore.presets.map(\.name) == session.presetCatalog else {
            discardSession(id: session.id)
            throw PresetPackageError.catalogChanged
        }

        guard selectedIDs.isSubset(of: Set(session.manifest.presets.map(\.sourceID))) else { throw PresetPackageError.malformedPackage }
        let textureIDs = Set(session.manifest.presets.filter { selectedIDs.contains($0.sourceID) }.compactMap { $0.texture?.id })
        let installation: TexturePackageInstallation
        do { installation = try textureStore.installValidatedPackageTextures(session.embeddedPayloads.filter { textureIDs.contains($0.sourceID) }) }
        catch {
            discardSession(id: session.id)
            throw PresetPackageError.persistenceFailed
        }

        return try publishInstallation(installation, session: session, selectedIDs: selectedIDs)
    }

    func commitImportInBackground(_ preview: PresetPackageImportPreview, selectedIDs: Set<String>) async throws -> PresetPackageImportResult {
        guard !selectedIDs.isEmpty else { throw PresetPackageError.noPresetsSelected }
        guard let session = sessions[preview.id], session.tokenIdentity == ObjectIdentifier(preview.token) else {
            throw PresetPackageError.previewExpired
        }
        guard selectedIDs.isSubset(of: Set(session.manifest.presets.map(\.sourceID))) else { throw PresetPackageError.malformedPackage }
        let textureIDs = Set(session.manifest.presets.filter { selectedIDs.contains($0.sourceID) }.compactMap { $0.texture?.id })
        let stage = try await textureStore.stageValidatedPackageTextures(session.embeddedPayloads.filter { textureIDs.contains($0.sourceID) })
        try Task.checkCancellation()
        guard sessions[preview.id] === session else { throw PresetPackageError.previewExpired }
        guard presetStore.presets.map(\.name) == session.presetCatalog else { throw PresetPackageError.catalogChanged }
        let installation = try textureStore.installStagedPackageTextures(stage)
        return try publishInstallation(installation, session: session, selectedIDs: selectedIDs)
    }

    private func publishInstallation(_ installation: TexturePackageInstallation, session: ImportSession,
                                     selectedIDs: Set<String>) throws -> PresetPackageImportResult {
        var drafts: [ImportedPresetDraft] = []
        for (index, preset) in session.manifest.presets.enumerated() where selectedIDs.contains(preset.sourceID) {
            var settings = preset.settings
            if let texture = preset.texture, texture.kind == .embedded {
                guard let localID = installation.sourceToLocalID[texture.id] else {
                    textureStore.rollbackPackageInstallation(installation)
                    discardSession(id: session.id)
                    throw PresetPackageError.persistenceFailed
                }
                settings.textureID = localID
            }
            drafts.append(ImportedPresetDraft(name: session.finalNames[index], settings: settings))
        }

        do { _ = try presetStore.importUserPresets(drafts) }
        catch {
            textureStore.rollbackPackageInstallation(installation)
            discardSession(id: session.id)
            throw PresetPackageError.persistenceFailed
        }
        discardSession(id: session.id)
        return PresetPackageImportResult(
            presetCount: drafts.count,
            newTextureCount: installation.newTextureCount
        )
    }

    private func discardSession(id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        try? fileManager.removeItem(at: session.extractionDirectory)
    }

    nonisolated private static func validateExtractedTree(at root: URL, expectedEntries: Set<String>, limits: PresetPackageLimits) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isHiddenKey
            ],
            options: []
        ) else { throw PresetPackageError.malformedPackage }

        var actual = Set<String>()
        var total: Int64 = 0
        let rootComponents = root.resolvingSymlinksInPath().pathComponents
        for case let url as URL in enumerator {
            let resolvedComponents = url.resolvingSymlinksInPath().pathComponents
            guard resolvedComponents.starts(with: rootComponents),
                  resolvedComponents.count > rootComponents.count else {
                throw PresetPackageError.unsafeArchive
            }
            let relative = resolvedComponents.dropFirst(rootComponents.count).joined(separator: "/")
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isHiddenKey
            ])
            guard values.isHidden != true, values.isSymbolicLink != true else {
                throw PresetPackageError.unsafeArchive
            }
            if values.isDirectory == true {
                guard relative == "textures" else { throw PresetPackageError.unsafeArchive }
                actual.insert("textures/")
            } else {
                guard values.isRegularFile == true,
                      PresetPackagePath(relative) != nil else {
                    throw PresetPackageError.unsafeArchive
                }
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                guard (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1 == 1 else {
                    throw PresetPackageError.unsafeArchive
                }
                total += Int64(values.fileSize ?? 0)
                guard total <= limits.maximumExtractedBytes else {
                    throw PresetPackageError.limitsExceeded
                }
                actual.insert(relative)
            }
        }
        let normalizedExpected = expectedEntries.union(
            expectedEntries.contains(where: { $0.hasPrefix("textures/") && $0.hasSuffix(".png") })
                ? ["textures/"] : []
        )
        guard actual == normalizedExpected else { throw PresetPackageError.unsafeArchive }
    }

    nonisolated private static func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw PresetPackageError.malformedPackage
        }
        return size.int64Value
    }

    nonisolated private static func boundedCopy(from source: URL, to destination: URL, maximumBytes: Int64) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PresetPackageError.persistenceFailed }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var count: Int64 = 0
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= maximumBytes else { throw PresetPackageError.limitsExceeded }
            try output.write(contentsOf: data)
        }
    }

    nonisolated private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    nonisolated private static func validateStrings(_ manifest: PresetPackageManifest, limits: PresetPackageLimits) throws {
        let strings = [manifest.createdBy, manifest.format] + manifest.presets.flatMap {
            [$0.sourceID, $0.name, $0.texture?.id ?? "", $0.texture?.path ?? "", $0.texture?.sha256 ?? "", $0.settings.textureID ?? ""]
        }
        guard strings.allSatisfy({ $0.utf8.count <= limits.maximumStringBytes && !$0.contains("\0") }) else {
            throw PresetPackageError.limitsExceeded
        }
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func isLowercaseDigest(_ value: String) -> Bool {
        let lowercaseHex = Set("0123456789abcdef")
        return value.count == 64 && value.allSatisfy(lowercaseHex.contains)
    }
}
