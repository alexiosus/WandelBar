import CryptoKit
import Foundation

struct TextureFileIdentity: Equatable, Sendable {
    let inode: UInt64
    let size: UInt64
    let modified: Date

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw TextureAssetStore.StoreError.cannotWrite
        }
        self.inode = inode.uint64Value
        self.size = size.uint64Value
        self.modified = modified
    }
}

/// Unpublished files, prepared on the same volume as the texture store for atomic moves.
final class TexturePackageStage: Sendable {
    let directory: URL
    let previousAssets: [TextureAsset]
    let previousMetadata: Data?
    let additions: [TextureAsset]
    let mapping: [String: String]
    let existingFiles: [String: TextureFileIdentity]
    let stagedNames: [String]

    init(directory: URL, previousAssets: [TextureAsset], previousMetadata: Data?, additions: [TextureAsset],
         mapping: [String: String], existingFiles: [String: TextureFileIdentity], stagedNames: [String]) {
        self.directory = directory
        self.previousAssets = previousAssets
        self.previousMetadata = previousMetadata
        self.additions = additions
        self.mapping = mapping
        self.existingFiles = existingFiles
        self.stagedNames = stagedNames
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    nonisolated static func prepare(payloads: [PackageTexturePayload], directory: URL,
        previousAssets: [TextureAsset], previousMetadata: Data?) throws -> TexturePackageStage {
        try Task.checkCancellation()
        let manager = FileManager.default
        let staging = directory.appendingPathComponent(".package-stage-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var finished = false
        defer { if !finished { try? manager.removeItem(at: staging) } }
        var additions: [TextureAsset] = [], mapping: [String: String] = [:]
        var existing: [String: TextureFileIdentity] = [:], names: [String] = []
        var seen = Set<String>()
        for payload in payloads {
            try Task.checkCancellation()
            let digest = SHA256.hash(data: payload.pngData).map { String(format: "%02x", $0) }.joined()
            guard payload.sha256 == digest, payload.sourceID == "custom.\(digest)" else {
                throw TextureAssetStore.StoreError.cannotDecode
            }
            let id = "custom.\(digest)", name = "\(digest).png"
            mapping[payload.sourceID] = id
            guard seen.insert(digest).inserted else { continue }
            if !previousAssets.contains(where: { $0.id == id }) {
                additions.append(TextureAsset(id: id, name: payload.name, kind: .custom, fileName: name))
            }
            let destination = directory.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) {
                let identity = try TextureFileIdentity(destination)
                guard identity.size == payload.pngData.count,
                      try Data(contentsOf: destination) == payload.pngData,
                      try TextureFileIdentity(destination) == identity else { throw TextureAssetStore.StoreError.cannotWrite }
                existing[name] = identity
            } else {
                let target = staging.appendingPathComponent(name)
                guard manager.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw TextureAssetStore.StoreError.cannotWrite
                }
                let file = try FileHandle(forWritingTo: target)
                defer { try? file.close() }
                for offset in stride(from: 0, to: payload.pngData.count, by: 64 * 1024) {
                    try Task.checkCancellation()
                    try file.write(contentsOf: payload.pngData.subdata(in: offset..<min(offset + 64 * 1024, payload.pngData.count)))
                }
                names.append(name)
            }
        }
        try Task.checkCancellation()
        finished = true
        return TexturePackageStage(directory: staging, previousAssets: previousAssets, previousMetadata: previousMetadata,
            additions: additions, mapping: mapping, existingFiles: existing, stagedNames: names)
    }
}
