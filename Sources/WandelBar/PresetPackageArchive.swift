import CArchive
import Foundation
import Darwin

protocol PresetPackageArchiving: Sendable {
    func createArchive(from sourceDirectory: URL, at destinationURL: URL) throws
    func listEntries(in archiveURL: URL) throws -> [String]
    func extractArchive(at archiveURL: URL, to destinationDirectory: URL) throws
}

/// ZIP decoding never invokes an external process or delegates filesystem writes to the decoder.
struct SystemPresetPackageArchive: PresetPackageArchiving {
    var limits: PresetPackageLimits = .default

    func listEntries(in archiveURL: URL) throws -> [String] {
        try read(archiveURL, destination: nil)
    }

    func extractArchive(at archiveURL: URL, to destinationDirectory: URL) throws {
        // Only a fresh private directory may be used: no existing link can redirect writes.
        guard !FileManager.default.fileExists(atPath: destinationDirectory.path) else {
            throw PresetPackageError.unsafeArchive
        }
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do { _ = try read(archiveURL, destination: destinationDirectory) }
        catch { try? FileManager.default.removeItem(at: destinationDirectory); throw error }
    }

    private func read(_ url: URL, destination: URL?) throws -> [String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size <= limits.maximumCompressedBytes else { throw PresetPackageError.limitsExceeded }
        let expectedNames = try PresetZIPDirectory.validate(url, limits: limits)
        guard let reader = archive_read_new() else { throw PresetPackageError.malformedPackage }
        defer { archive_read_free(reader) }
        archive_read_support_format_zip_seekable(reader)
        guard archive_read_open_filename(reader, url.path, 64 * 1024) == ARCHIVE_OK else {
            throw PresetPackageError.malformedPackage
        }
        var entries: [String] = [], seen = Set<String>()
        var total: Int64 = 0
        var textureCount = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let entry, let name = archive_entry_pathname_utf8(entry) else {
                throw PresetPackageError.malformedPackage
            }
            let path = String(cString: name)
            guard path.utf8.count <= 256, PresetPackagePath(path) != nil,
                  seen.insert(path).inserted,
                  archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil,
                  archive_entry_is_encrypted(entry) == 0 else { throw PresetPackageError.unsafeArchive }
            guard seen.count <= limits.maximumTextures + 2 else { throw PresetPackageError.limitsExceeded }
            let directory = path == "textures/"
            if path.hasSuffix(".png") { textureCount += 1 }
            guard textureCount <= limits.maximumTextures else { throw PresetPackageError.limitsExceeded }
            guard archive_entry_filetype(entry) == (directory ? 0o040000 : 0o100000) else {
                throw PresetPackageError.unsafeArchive
            }
            let declared = archive_entry_size(entry)
            let entryLimit = path == "manifest.json" ? limits.maximumManifestBytes : limits.maximumExtractedBytes
            guard declared >= 0, declared <= entryLimit, declared <= limits.maximumExtractedBytes - total else {
                throw PresetPackageError.limitsExceeded
            }
            var handle: FileHandle?
            if let destination {
                let output = destination.appendingPathComponent(path)
                if directory {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw PresetPackageError.persistenceFailed
                    }
                    handle = try FileHandle(forWritingTo: output)
                }
            }
            defer { try? handle?.close() }
            var entryBytes: Int64 = 0
            while true {
                try Task.checkCancellation()
                let count = archive_read_data(reader, &buffer, buffer.count)
                guard count >= 0 else { throw PresetPackageError.malformedPackage }
                if count == 0 { break }
                entryBytes += Int64(count)
                total += Int64(count)
                guard !directory, entryBytes <= entryLimit, total <= limits.maximumExtractedBytes else {
                    throw PresetPackageError.limitsExceeded
                }
                try handle?.write(contentsOf: Data(buffer.prefix(count)))
            }
            guard entryBytes == declared else { throw PresetPackageError.malformedPackage }
            entries.append(path)
        }
        guard seen == Set(expectedNames) else { throw PresetPackageError.malformedPackage }
        return entries
    }

    func createArchive(from sourceDirectory: URL, at destinationURL: URL) throws {
        try writeArchive(from: sourceDirectory, at: destinationURL, sharingFiles: nil)
    }

    /// Producer-only wrapper. Import continues to accept only the preset package layout.
    func createSharingArchive(from sourceDirectory: URL, at destinationURL: URL, allowedFileNames: Set<String>) throws {
        guard !allowedFileNames.isEmpty, allowedFileNames.count <= 10,
              allowedFileNames.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") && $0.utf8.count <= 128 }) else {
            throw PresetPackageError.unsafeArchive
        }
        try writeArchive(from: sourceDirectory, at: destinationURL, sharingFiles: allowedFileNames)
    }

    private func writeArchive(from sourceDirectory: URL, at destinationURL: URL, sharingFiles: Set<String>?) throws {
        guard let writer = archive_write_new() else { throw PresetPackageError.persistenceFailed }
        defer { archive_write_free(writer) }
        guard archive_write_set_format_zip(writer) == ARCHIVE_OK,
              archive_write_open_filename(writer, destinationURL.path) == ARCHIVE_OK else {
            throw PresetPackageError.persistenceFailed
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destinationURL) } }
        guard let resolved = realpath(sourceDirectory.path, nil) else { throw PresetPackageError.persistenceFailed }
        let sourcePath = String(cString: resolved)
        free(resolved)
        guard let enumerator = FileManager.default.enumerator(at: sourceDirectory, includingPropertiesForKeys: nil) else {
            throw PresetPackageError.persistenceFailed
        }
        var total: Int64 = 0, count = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let directory = attributes[.type] as? FileAttributeType == .typeDirectory
            let path = String(url.path.dropFirst(sourcePath.count + 1)) + (directory ? "/" : "")
            guard (sharingFiles.map { $0.contains(path) && !directory } ?? (PresetPackagePath(path) != nil)),
                  directory || (attributes[.type] as? FileAttributeType == .typeRegular && (attributes[.referenceCount] as? NSNumber)?.intValue == 1) else {
                throw PresetPackageError.unsafeArchive
            }
            count += 1
            let size = directory ? 0 : (attributes[.size] as? NSNumber)?.int64Value ?? 0
            total += size
            guard count <= limits.maximumTextures + 2, total <= limits.maximumExtractedBytes,
                  path != "manifest.json" || size <= limits.maximumManifestBytes else { throw PresetPackageError.limitsExceeded }
            guard let entry = archive_entry_new() else { throw PresetPackageError.persistenceFailed }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, path)
            archive_entry_set_filetype(entry, directory ? 0o040000 : 0o100000)
            archive_entry_set_perm(entry, directory ? 0o755 : 0o644)
            archive_entry_set_size(entry, size)
            guard archive_write_header(writer, entry) == ARCHIVE_OK else { throw PresetPackageError.persistenceFailed }
            if !directory {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var fileBytes: Int64 = 0
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    fileBytes += Int64(data.count)
                    guard fileBytes <= size else { throw PresetPackageError.limitsExceeded }
                    let written = data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
                    guard written == data.count else { throw PresetPackageError.persistenceFailed }
                }
                guard fileBytes == size else { throw PresetPackageError.persistenceFailed }
            }
        }
        guard archive_write_close(writer) == ARCHIVE_OK else { throw PresetPackageError.persistenceFailed }
        let size = try FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber
        guard let size, size.int64Value <= limits.maximumCompressedBytes else { throw PresetPackageError.limitsExceeded }
        completed = true
    }
}
