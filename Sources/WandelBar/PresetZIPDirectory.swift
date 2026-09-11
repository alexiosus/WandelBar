import Foundation

/// Bound the central directory before libarchive allocates its seekable ZIP index.
/// ZIP64 and multi-volume archives are unnecessary at this format's small size limits.
enum PresetZIPDirectory {
    static func validate(_ url: URL, limits: PresetPackageLimits, sharingWrapper: Bool = false) throws -> [String] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 22, size <= UInt64(max(0, limits.maximumCompressedBytes)) else { throw PresetPackageError.limitsExceeded }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw PresetPackageError.malformedPackage }
            if count == 0 { return Data() }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else { throw PresetPackageError.malformedPackage }
            return data
        }
        let tailOffset = size - min(size, 65557)
        let tail = try read(tailOffset, Int(size - tailOffset))
        var end: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(index) == 0x06054b50, index + 22 + Int(tail.u16(index + 20)) == tail.count { end = index; break }
        }
        guard let end, tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == tail.u16(end + 10) else { throw PresetPackageError.malformedPackage }
        let count = Int(tail.u16(end + 10))
        guard count > 0, count <= (sharingWrapper ? 1 : limits.maximumTextures + 2) else { throw PresetPackageError.limitsExceeded }
        let directorySize = UInt64(tail.u32(end + 12)), directoryOffset = UInt64(tail.u32(end + 16))
        guard directoryOffset + directorySize == tailOffset + UInt64(end), directorySize <= UInt64(count * (46 + 256 + 65535 + 65535)) else {
            throw PresetPackageError.malformedPackage
        }
        var offset = directoryOffset, names: [String] = [], seen = Set<String>()
        var total: UInt64 = 0, textures = 0
        for _ in 0..<count {
            try Task.checkCancellation()
            let header = try read(offset, 46)
            guard header.u32(0) == 0x02014b50, header.u16(34) == 0 else { throw PresetPackageError.malformedPackage }
            let nameSize = Int(header.u16(28)), extraSize = Int(header.u16(30)), commentSize = Int(header.u16(32))
            guard nameSize > 0, nameSize <= 256 else { throw PresetPackageError.unsafeArchive }
            let nameData = try read(offset + 46, nameSize)
            guard !nameData.contains(0), let name = String(data: nameData, encoding: .utf8),
                  (sharingWrapper ? name == "Presets.wandelbar-presets" : PresetPackagePath(name) != nil), seen.insert(name).inserted else { throw PresetPackageError.unsafeArchive }
            let mode = header.u32(38) >> 16
            let kind = mode & 0o170000
            guard kind == 0 || kind == (name == "textures/" ? 0o040000 : 0o100000),
                  header.u16(8) & 0x41 == 0, [0, 8].contains(header.u16(10)) else { throw PresetPackageError.unsafeArchive }
            let expanded = UInt64(header.u32(24)), compressed = UInt64(header.u32(20))
            let cap = name == "manifest.json" ? limits.maximumManifestBytes : limits.maximumExtractedBytes
            guard expanded <= UInt64(max(0, cap)), compressed <= size,
                  name != "textures/" || expanded == 0 else { throw PresetPackageError.limitsExceeded }
            total += expanded
            if name.hasSuffix(".png") { textures += 1 }
            guard total <= UInt64(max(0, limits.maximumExtractedBytes)), textures <= limits.maximumTextures else { throw PresetPackageError.limitsExceeded }
            // Reject ZIP Unix link-bearing extensions; ordinary timestamps and UID/GID are harmless.
            let extra = try read(offset + 46 + UInt64(nameSize), extraSize)
            var cursor = 0
            while cursor < extra.count {
                guard cursor + 4 <= extra.count else { throw PresetPackageError.malformedPackage }
                let type = extra.u16(cursor), length = Int(extra.u16(cursor + 2))
                guard cursor + 4 + length <= extra.count else { throw PresetPackageError.malformedPackage }
                guard type != 0x756e, type != 0x000d || length <= 12 else { throw PresetPackageError.unsafeArchive }
                cursor += 4 + length
            }
            let localOffset = UInt64(header.u32(42))
            let local = try read(localOffset, 30)
            guard local.u32(0) == 0x04034b50, local.u16(6) == header.u16(8), local.u16(8) == header.u16(10),
                  Int(local.u16(26)) == nameSize,
                  try read(localOffset + 30, nameSize) == nameData,
                  localOffset + 30 + UInt64(nameSize) + UInt64(local.u16(28)) + compressed <= directoryOffset else {
                throw PresetPackageError.malformedPackage
            }
            names.append(name)
            offset += UInt64(46 + nameSize + extraSize + commentSize)
            guard offset <= directoryOffset + directorySize else { throw PresetPackageError.malformedPackage }
        }
        guard offset == directoryOffset + directorySize, seen.contains(sharingWrapper ? "Presets.wandelbar-presets" : "manifest.json") else { throw PresetPackageError.malformedPackage }
        return names
    }
}

private extension Data {
    func u16(_ index: Int) -> UInt16 { UInt16(self[index]) | UInt16(self[index + 1]) << 8 }
    func u32(_ index: Int) -> UInt32 { UInt32(u16(index)) | UInt32(u16(index + 2)) << 16 }
}
