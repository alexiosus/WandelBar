import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class TextureAssetStore {
    enum StoreError: Error, Equatable, LocalizedError {
        case unsupportedFormat
        case cannotDecode
        case cannotEncode
        case cannotWrite

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "Choose a PNG, JPEG, or HEIC image."
            case .cannotDecode:
                return "The selected image could not be decoded."
            case .cannotEncode:
                return "The selected image could not be normalized."
            case .cannotWrite:
                return "The texture could not be saved."
            }
        }
    }

    static let shared = TextureAssetStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let texturesDirectory: URL
    private let builtInURL: @Sendable (TextureAsset) -> URL?
    private let persistData: ((Data) -> Bool)?
    private var storedCustomAssets: [TextureAsset]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "WandelBar.textureAssets.v1",
        texturesDirectory: URL? = nil,
        builtInURL: @escaping @Sendable (TextureAsset) -> URL? = TextureAssetStore.bundledURL,
        persistData: ((Data) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.texturesDirectory = texturesDirectory ?? Self.defaultTexturesDirectory()
        self.builtInURL = builtInURL
        self.persistData = persistData

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([TextureAsset].self, from: data) {
            storedCustomAssets = decoded.filter { asset in
                guard asset.kind == .custom,
                      let fileName = asset.fileName else {
                    return false
                }
                return URL(fileURLWithPath: fileName).lastPathComponent == fileName
            }
        } else {
            storedCustomAssets = []
        }
    }

    var assets: [TextureAsset] {
        TextureAsset.builtIns + customAssets
    }

    var customAssets: [TextureAsset] {
        storedCustomAssets.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func asset(id: String) -> TextureAsset? {
        assets.first { $0.id == id }
    }

    func resolvedURL(for id: String?) -> URL? {
        guard let id else { return nil }

        let url: URL?
        if let asset = TextureAsset.builtIns.first(where: { $0.id == id }) {
            url = builtInURL(asset)
        } else if let asset = storedCustomAssets.first(where: { $0.id == id }),
                  let fileName = asset.fileName {
            url = texturesDirectory.appendingPathComponent(fileName, isDirectory: false)
        } else {
            url = nil
        }

        guard let url,
              FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return url
    }

    func isAvailable(id: String) -> Bool {
        resolvedURL(for: id) != nil
    }

    func importTexture(from sourceURL: URL) async throws -> TextureAsset {
        let normalizedPNG = try await Task.detached(priority: .userInitiated) {
            try Self.normalizeTexture(at: sourceURL)
        }.value

        let digest = SHA256.hash(data: normalizedPNG)
            .map { String(format: "%02x", $0) }
            .joined()
        let id = "custom.\(digest)"
        let fileName = "\(digest).png"
        let existing = storedCustomAssets.first { $0.id == id }
        let name = existing?.name ?? Self.displayName(for: sourceURL)
        let asset = existing ?? TextureAsset(
            id: id,
            name: name,
            kind: .custom,
            fileName: fileName
        )
        let updatedAssets = existing == nil ? storedCustomAssets + [asset] : storedCustomAssets

        guard let metadata = try? JSONEncoder().encode(updatedAssets) else {
            throw StoreError.cannotWrite
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: texturesDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw StoreError.cannotWrite
        }

        let destinationURL = texturesDirectory.appendingPathComponent(fileName, isDirectory: false)
        var createdDestination = false
        if !fileManager.fileExists(atPath: destinationURL.path) {
            let temporaryURL = texturesDirectory.appendingPathComponent(
                ".import-\(UUID().uuidString).png",
                isDirectory: false
            )
            do {
                try normalizedPNG.write(to: temporaryURL, options: .atomic)
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                createdDestination = true
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw StoreError.cannotWrite
            }
        }

        guard persistMetadata(metadata) else {
            if createdDestination {
                try? fileManager.removeItem(at: destinationURL)
            }
            throw StoreError.cannotWrite
        }

        storedCustomAssets = updatedAssets
        return asset
    }

    func installPackageTextures(
        _ payloads: [PackageTexturePayload]
    ) throws -> TexturePackageInstallation {
        let previousAssets = storedCustomAssets
        let previousMetadata = defaults.data(forKey: storageKey)
        var sourceToLocalID: [String: String] = [:]
        var additions: [TextureAsset] = []

        for payload in payloads {
            guard Self.isLowercaseDigest(payload.sha256),
                  Self.sha256(payload.pngData) == payload.sha256 else {
                throw StoreError.cannotDecode
            }
            let normalized = try Self.normalizeTextureData(payload.pngData)
            guard normalized == payload.pngData else { throw StoreError.cannotEncode }

            let id = "custom.\(payload.sha256)"
            sourceToLocalID[payload.sourceID] = id
            guard !previousAssets.contains(where: { $0.id == id }),
                  !additions.contains(where: { $0.id == id }) else {
                continue
            }
            let trimmedName = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            additions.append(TextureAsset(
                id: id,
                name: trimmedName.isEmpty ? "Texture" : trimmedName,
                kind: .custom,
                fileName: "\(payload.sha256).png"
            ))
        }

        let updatedAssets = previousAssets + additions
        guard let metadata = try? JSONEncoder().encode(updatedAssets) else {
            throw StoreError.cannotWrite
        }

        let fileManager = FileManager.default
        var createdFileNames: [String] = []
        do {
            try fileManager.createDirectory(at: texturesDirectory, withIntermediateDirectories: true)
            var uniquePayloads: [String: PackageTexturePayload] = [:]
            for payload in payloads { uniquePayloads[payload.sha256] = payload }
            for (digest, payload) in uniquePayloads {
                let fileName = "\(digest).png"
                let destination = texturesDirectory.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: destination.path) {
                    guard (try? Data(contentsOf: destination)) == payload.pngData else {
                        throw StoreError.cannotWrite
                    }
                    continue
                }
                let temporary = texturesDirectory.appendingPathComponent(".package-\(UUID().uuidString).png")
                do {
                    try payload.pngData.write(to: temporary, options: .atomic)
                    try fileManager.moveItem(at: temporary, to: destination)
                    createdFileNames.append(fileName)
                } catch {
                    try? fileManager.removeItem(at: temporary)
                    throw StoreError.cannotWrite
                }
            }
            guard persistMetadata(metadata) else { throw StoreError.cannotWrite }
            storedCustomAssets = updatedAssets
        } catch {
            for fileName in createdFileNames {
                try? fileManager.removeItem(at: texturesDirectory.appendingPathComponent(fileName))
            }
            restoreMetadata(previousMetadata)
            storedCustomAssets = previousAssets
            throw error
        }

        return TexturePackageInstallation(
            sourceToLocalID: sourceToLocalID,
            newTextureCount: additions.count,
            previousAssets: previousAssets,
            previousMetadata: previousMetadata,
            createdFileNames: createdFileNames
        )
    }

    func rollbackPackageInstallation(_ receipt: TexturePackageInstallation) {
        for fileName in receipt.createdFileNames {
            try? FileManager.default.removeItem(
                at: texturesDirectory.appendingPathComponent(fileName)
            )
        }
        restoreMetadata(receipt.previousMetadata)
        storedCustomAssets = receipt.previousAssets
    }

    nonisolated static func bundledAzureURL() -> URL? {
        bundledURL(for: TextureAsset.azureReflection)
    }

    nonisolated static func bundledURL(for asset: TextureAsset) -> URL? {
        guard asset.kind == .builtIn,
              let fileName = asset.fileName else {
            return nil
        }
        let resourceName = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        return Bundle.main.url(
            forResource: resourceName,
            withExtension: fileExtension,
            subdirectory: "Textures"
        ) ?? Bundle.module.url(
            forResource: resourceName,
            withExtension: fileExtension,
            subdirectory: "Textures"
        )
    }

    nonisolated private static func defaultTexturesDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WandelBar", isDirectory: true)
            .appendingPathComponent("Textures", isDirectory: true)
    }

    nonisolated private static func displayName(for sourceURL: URL) -> String {
        let name = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Texture" : name
    }

    nonisolated static func normalizeTextureData(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw StoreError.cannotDecode
        }
        return try normalizeTextureSource(source)
    }

    nonisolated private static func normalizeTexture(at sourceURL: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw StoreError.cannotDecode
        }
        return try normalizeTextureSource(source)
    }

    nonisolated private static func normalizeTextureSource(_ source: CGImageSource) throws -> Data {
        guard let sourceType = CGImageSourceGetType(source) as String? else {
            throw StoreError.cannotDecode
        }
        let supportedTypes = [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier]
        guard supportedTypes.contains(sourceType) else {
            throw StoreError.unsupportedFormat
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            throw StoreError.cannotDecode
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: thumbnail.width,
                  height: thumbnail.height,
                  bitsPerComponent: 8,
                  bytesPerRow: thumbnail.width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw StoreError.cannotEncode
        }
        context.interpolationQuality = .high
        context.draw(
            thumbnail,
            in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height)
        )
        guard let normalizedImage = context.makeImage() else {
            throw StoreError.cannotEncode
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw StoreError.cannotEncode
        }
        CGImageDestinationAddImage(destination, normalizedImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StoreError.cannotEncode
        }
        return output as Data
    }

    private func persistMetadata(_ data: Data) -> Bool {
        if let persistData { return persistData(data) }
        defaults.set(data, forKey: storageKey)
        return defaults.data(forKey: storageKey) == data
    }

    private func restoreMetadata(_ data: Data?) {
        if let data {
            defaults.set(data, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
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
