import Foundation
import CArchive

/// A signed attachment ZIP has one regular root package. No decoder writes to disk.
enum CommunityPackageAttachment {
    static func unwrap(_ data: Data) throws -> Data {
        let cap = CommunityCatalogVerifier.maximumPackageBytes
        guard !data.isEmpty, data.count <= cap else { throw CommunityCatalogError.tooLarge }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try data.write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try PresetZIPDirectory.validate(temporary, limits: .init(maximumPresets: 100, maximumTextures: 100,
            maximumCompressedBytes: Int64(cap), maximumExtractedBytes: Int64(cap)), sharingWrapper: true)
        return try data.withUnsafeBytes { bytes in
            guard let reader = archive_read_new() else { throw PresetPackageError.malformedPackage }
            defer { archive_read_free(reader) }
            archive_read_support_format_zip_seekable(reader)
            guard archive_read_open_memory(reader, bytes.baseAddress, bytes.count) == ARCHIVE_OK else { throw PresetPackageError.malformedPackage }
            var entry: OpaquePointer?
            guard archive_read_next_header(reader, &entry) == ARCHIVE_OK, let file = entry,
                  let name = archive_entry_pathname_utf8(file), String(cString: name) == "Presets.wandelbar-presets",
                  archive_entry_filetype(file) == 0o100000, archive_entry_symlink(file) == nil,
                  archive_entry_hardlink(file) == nil, archive_entry_is_encrypted(file) == 0,
                  archive_entry_size(file) > 0, archive_entry_size(file) <= Int64(cap) else { throw PresetPackageError.unsafeArchive }
            let declared = archive_entry_size(file)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let count = archive_read_data(reader, &buffer, buffer.count)
                guard count >= 0 else { throw PresetPackageError.malformedPackage }
                if count == 0 { break }
                guard count <= cap - output.count else { throw CommunityCatalogError.tooLarge }
                output.append(contentsOf: buffer.prefix(count))
            }
            guard output.count == declared, archive_read_next_header(reader, &entry) == ARCHIVE_EOF else { throw PresetPackageError.malformedPackage }
            return output
        }
    }
}
