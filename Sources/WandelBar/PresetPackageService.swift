import CryptoKit
import Foundation

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
        self.archive = archive
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
                var reference: PresetPackageTextureReference?
                if let textureID = preset.settings.textureID {
                    guard let asset = textureStore.asset(id: textureID) else {
                        throw PresetPackageError.sourceTextureMissing(textureID)
                    }
                    switch asset.kind {
                    case .builtIn:
                        guard textureStore.isAvailable(id: textureID) else {
                            throw PresetPackageError.sourceTextureMissing(textureID)
                        }
                        reference = PresetPackageTextureReference(
                            kind: .builtIn, id: textureID, path: nil, sha256: nil
                        )
                    case .custom:
                        guard let url = textureStore.resolvedURL(for: textureID),
                              let data = try? Data(contentsOf: url) else {
                            throw PresetPackageError.sourceTextureMissing(textureID)
                        }
                        let digest = Self.sha256(data)
                        guard textureID == "custom.\(digest)",
                              (try? TextureAssetStore.normalizeTextureData(data)) == data else {
                            throw PresetPackageError.sourceTextureMissing(textureID)
                        }
                        embedded[digest] = data
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
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            try archive.createArchive(from: staging, at: temporaryArchive)

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryArchive)
            } else {
                try fileManager.moveItem(at: temporaryArchive, to: destinationURL)
            }
            return PresetPackageExportSummary(
                presetCount: presets.count,
                textureCount: embedded.count
            )
        } catch let error as PresetPackageError {
            throw error
        } catch {
            throw PresetPackageError.persistenceFailed
        }
    }

    func prepareImport(from packageURL: URL) async throws -> PresetPackageImportPreview {
        let compressedSize = try fileSize(at: packageURL)
        guard compressedSize <= limits.maximumCompressedBytes else {
            throw PresetPackageError.limitsExceeded
        }

        let entries: [String]
        do { entries = try archive.listEntries(in: packageURL) }
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
        do { try archive.extractArchive(at: packageURL, to: extraction) }
        catch { throw PresetPackageError.malformedPackage }

        try validateExtractedTree(at: extraction, expectedEntries: seen)
        let manifestURL = extraction.appendingPathComponent("manifest.json")
        let manifest: PresetPackageManifest
        do { manifest = try JSONDecoder().decode(PresetPackageManifest.self, from: Data(contentsOf: manifestURL)) }
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

        var referencedPaths = Set<String>()
        var payloadsByID: [String: PackageTexturePayload] = [:]
        var sourceIDs = Set<String>()
        for preset in manifest.presets {
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
                      textureStore.isAvailable(id: texture.id) else {
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
        shouldRemove = false
        return PresetPackageImportPreview(
            presets: zip(manifest.presets, finalNames).map { preset, finalName in
                PresetPackageImportPreview.Preset(
                    id: preset.sourceID,
                    sourceName: preset.name,
                    finalName: finalName,
                    wasRenamed: preset.name != finalName
                )
            },
            embeddedTextureCount: payloadsByID.count,
            token: token
        )
    }

    func discardImport(_ preview: PresetPackageImportPreview) {
        guard let session = sessions[preview.id],
              session.tokenIdentity == ObjectIdentifier(preview.token) else { return }
        discardSession(id: preview.id)
    }

    func commitImport(_ preview: PresetPackageImportPreview) throws -> PresetPackageImportResult {
        guard let session = sessions[preview.id],
              session.tokenIdentity == ObjectIdentifier(preview.token) else {
            throw PresetPackageError.previewExpired
        }
        guard presetStore.presets.map(\.name) == session.presetCatalog else {
            discardSession(id: session.id)
            throw PresetPackageError.catalogChanged
        }

        let installation: TexturePackageInstallation
        do { installation = try textureStore.installPackageTextures(session.embeddedPayloads) }
        catch {
            discardSession(id: session.id)
            throw PresetPackageError.persistenceFailed
        }

        var drafts: [ImportedPresetDraft] = []
        for (index, preset) in session.manifest.presets.enumerated() {
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

    private func validateExtractedTree(at root: URL, expectedEntries: Set<String>) throws {
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

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw PresetPackageError.malformedPackage
        }
        return size.int64Value
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func isLowercaseDigest(_ value: String) -> Bool {
        let lowercaseHex = Set("0123456789abcdef")
        return value.count == 64 && value.allSatisfy(lowercaseHex.contains)
    }
}
