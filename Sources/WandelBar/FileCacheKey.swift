import CryptoKit
import Foundation

enum FileCacheKey {
    /// A fixed-width filesystem-safe digest. Unlike truncated Base64, every input byte
    /// contributes to the name and path separators can never escape the cache directory.
    static func digest(_ components: [String]) -> String {
        let payload = components.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sourceSignature(for url: URL, pixelSize: CGSize) -> String {
        let standardizedURL = url.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey
        ])
        let contentDigest = (try? Data(contentsOf: standardizedURL, options: .mappedIfSafe))
            .map { data in
                SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
            } ?? "unreadable-content"

        return digest([
            standardizedURL.absoluteString,
            "\(Int(pixelSize.width))x\(Int(pixelSize.height))",
            values?.contentModificationDate?.timeIntervalSince1970.description ?? "unknown-date",
            values?.fileSize.map(String.init) ?? "unknown-size",
            contentDigest
        ])
    }
}
