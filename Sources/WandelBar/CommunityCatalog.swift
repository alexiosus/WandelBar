import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct CommunityCatalogConfiguration: Codable, Sendable {
    var publicKey: String
    var indexURL: URL = URL(string: "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/catalog.json")!
    var minimumSequence: Int = 1

    static func bundled() -> Self {
        guard let url = CommunityResources.url(for: "configuration"),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4096, let data = try? Data(contentsOf: url), data.count <= 4096,
              let configuration = try? JSONDecoder().decode(Self.self, from: data) else { return .init(publicKey: "") }
        return configuration
    }
}

struct CommunityCatalogEntry: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let author: String
    let summary: String
    let tags: [String]
    let sourceURL: URL
    let packageURL: URL
    let sha256: String
    let byteCount: Int
    var preview: CommunityPreviewMetadata? = nil
}

struct CommunityPreviewMetadata: Codable, Sendable, Equatable {
    let url: URL
    let sha256: String
    let byteCount: Int
    let width: Int
    let height: Int
}

struct CommunityCatalog: Codable, Sendable {
    let schemaVersion: Int
    let minimumClientVersion: Int
    let sequence: Int
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval
    let entries: [CommunityCatalogEntry]
}

struct CommunityCatalogSnapshot: Sendable {
    let catalog: CommunityCatalog
    let isCached: Bool
    let status: String
}

enum CommunityCatalogError: LocalizedError {
    case unavailable, invalidSignature, invalidCatalog, unsafeURL, tooLarge, digestMismatch, replay, expired
    case httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .httpStatus(let status): status == 404 ? "The curated catalogue has not been published yet. Visit Preset Exchange for submissions." : "The official catalogue server returned HTTP \(status). Try again later."
        case .unavailable: "The curated gallery is not configured in this build. Browse Preset Exchange for community submissions."
        case .invalidSignature: "The catalogue signature could not be verified."
        case .invalidCatalog: "The catalogue format or an entry is unsupported."
        case .unsafeURL: "The catalogue contains a download outside the official project."
        case .tooLarge: "The download exceeds the allowed size."
        case .digestMismatch: "The download does not match its signed size and checksum."
        case .replay: "An older or conflicting catalogue was rejected."
        case .expired: "The signed catalogue has expired. Refresh when a newer catalogue is available."
        }
    }
}

/// Shared by initial requests and URLSession's redirect callback. No credentials, alternate ports,
/// encoded path segments, query strings or non-project destinations can cross this boundary.
struct CommunityURLPolicy: Sendable {
    static let root = "/alexiosus/WandelBar/master/Community/"
    func allows(_ url: URL) -> Bool {
        if Self.attachmentID(url) != nil { return true }
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              c.host == "raw.githubusercontent.com", c.user == nil, c.password == nil,
              c.port == nil, c.query == nil, c.fragment == nil,
              !c.percentEncodedPath.contains("%"), !c.path.contains("..") else { return false }
        if c.path == Self.root + "catalog.json" { return true }
        if c.path.hasPrefix(Self.root + "previews/"), c.path.hasSuffix(".png") {
            return CommunityCatalogVerifier.isDigest(String(c.path.dropFirst((Self.root + "previews/").count).dropLast(4)))
        }
        let prefix = Self.root + "packages/"
        guard c.path.hasPrefix(prefix), c.path.hasSuffix(".wandelbar-presets") else { return false }
        let name = String(c.path.dropFirst(prefix.count).dropLast(".wandelbar-presets".count))
        return CommunityCatalogVerifier.isDigest(name)
    }
    static func attachmentID(_ url: URL) -> String? {
        let pattern = #"^https://github\.com/user-attachments/files/([1-9][0-9]{0,15})/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(zip|wandelbar-presets)$"#
        guard url.absoluteString.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return url.pathComponents.dropFirst(3).first
    }
    func allowsRedirect(to url: URL, count: Int) -> Bool { count <= 3 && allows(url) }
    func allowsResponse(_ url: URL, from original: URL, count: Int) -> Bool {
        guard (0...3).contains(count), allows(original) else { return false }
        if url == original { return true }
        guard let attachment = Self.attachmentID(original),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.host == "objects.githubusercontent.com",
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              c.percentEncodedPath == c.path, (c.query?.utf8.count ?? 0) <= 8192 else { return false }
        return c.path == "/github-production-repository-file-5c1aeb/1341390246/" + attachment
    }
    static func allowsSource(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "https",
              c.host == "github.com", c.user == nil, c.password == nil, c.port == nil,
              c.query == nil, c.fragment == nil, !c.percentEncodedPath.contains("%") else { return false }
        let prefix = "/alexiosus/WandelBar/discussions/"
        guard c.path.hasPrefix(prefix) else { return false }
        let number = c.path.dropFirst(prefix.count)
        return !number.isEmpty && number.count <= 16 && number.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

enum CommunityCatalogVerifier {
    static let maximumIndexBytes = 1_048_576
    static let maximumPackageBytes = 32 * 1_048_576
    static let maximumPreviewBytes = 8 * 1_048_576
    static let maximumLifetime: TimeInterval = 30 * 24 * 3600
    private struct Envelope: Decodable { let payload: String; let signature: String }
    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func verify(_ data: Data, configuration: CommunityCatalogConfiguration, now: Date, allowExpired: Bool = false) throws -> CommunityCatalog {
        guard data.count <= maximumIndexBytes else { throw CommunityCatalogError.tooLarge }
        guard let keyData = Data(base64Encoded: configuration.publicKey), keyData.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { throw CommunityCatalogError.unavailable }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload), payload.count <= 700_000,
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
              key.isValidSignature(signature, for: payload) else { throw CommunityCatalogError.invalidSignature }
        // Parse untrusted payload only after authenticating the exact original bytes.
        let catalog = try JSONDecoder().decode(CommunityCatalog.self, from: payload)
        guard catalog.schemaVersion == 1, (1...2).contains(catalog.minimumClientVersion),
              catalog.sequence >= max(1, configuration.minimumSequence), catalog.entries.count <= 200,
              catalog.issuedAt.isFinite, catalog.expiresAt.isFinite,
              catalog.issuedAt <= now.timeIntervalSince1970 + 300,
              catalog.expiresAt > catalog.issuedAt,
              catalog.expiresAt - catalog.issuedAt <= maximumLifetime else { throw CommunityCatalogError.invalidCatalog }
        guard allowExpired || catalog.expiresAt > now.timeIntervalSince1970 else { throw CommunityCatalogError.expired }
        var ids = Set<String>()
        for entry in catalog.entries {
            guard isDigest(entry.id), entry.id == entry.sha256, ids.insert(entry.id).inserted,
                  validText(entry.title, limit: 100), validText(entry.author, limit: 100),
                  validText(entry.summary, limit: 500), entry.tags.count <= 8,
                  Set(entry.tags).count == entry.tags.count, entry.tags.allSatisfy({ validText($0, limit: 30) }),
                  (1...maximumPackageBytes).contains(entry.byteCount) else { throw CommunityCatalogError.invalidCatalog }
            guard CommunityURLPolicy().allows(entry.packageURL),
                  (CommunityURLPolicy.attachmentID(entry.packageURL) != nil ||
                   entry.packageURL.path == CommunityURLPolicy.root + "packages/" + entry.sha256 + ".wandelbar-presets"),
                  CommunityURLPolicy.allowsSource(entry.sourceURL) else { throw CommunityCatalogError.unsafeURL }
            if let preview = entry.preview { try verifyPreviewMetadata(preview) }
        }
        return catalog
    }
    static func verifyPreviewMetadata(_ preview: CommunityPreviewMetadata) throws {
        guard isDigest(preview.sha256), (1...maximumPreviewBytes).contains(preview.byteCount),
              (1...2160).contains(preview.width), (1...4096).contains(preview.height),
              preview.width * preview.height <= 9_000_000 else { throw CommunityCatalogError.invalidCatalog }
        guard preview.url.absoluteString == "https://raw.githubusercontent.com" + CommunityURLPolicy.root + "previews/" + preview.sha256 + ".png" else { throw CommunityCatalogError.unsafeURL }
    }

    static func verifyPreview(_ data: Data, metadata: CommunityPreviewMetadata) throws {
        try verifyPreviewMetadata(metadata)
        // Authenticate bytes before exposing any image parser to them.
        try verifyPackage(data, sha256: metadata.sha256, byteCount: metadata.byteCount)
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == metadata.width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == metadata.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == metadata.width, image.height == metadata.height else { throw CommunityCatalogError.invalidCatalog }
    }

    private static func validText(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
    }
    static func verifyPackage(_ data: Data, sha256: String, byteCount: Int) throws {
        guard byteCount > 0, byteCount <= maximumPackageBytes, data.count == byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw CommunityCatalogError.digestMismatch }
    }
}

private final class CommunityRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0
    private let original: URL
    init(original: URL) { self.original = original }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let count = redirects
        lock.unlock()
        completionHandler(request.url.map { CommunityURLPolicy().allowsResponse($0, from: original, count: count) } == true ? request : nil)
    }
}

enum CommunityHTTPClient {
    static func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard CommunityURLPolicy().allows(url), limit > 0, limit <= CommunityCatalogVerifier.maximumPackageBytes else { throw CommunityCatalogError.unsafeURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = CommunityRedirectDelegate(original: url)
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData), delegate: delegate)
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url, CommunityURLPolicy().allowsResponse(finalURL, from: url, count: 3) else { throw CommunityCatalogError.unsafeURL }
        guard response.statusCode == 200 else { throw CommunityCatalogError.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= Int64(limit) else { throw CommunityCatalogError.tooLarge }
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw CommunityCatalogError.tooLarge }
            data.append(byte)
        }
        return data
    }
}

actor CommunityCatalogService {
    typealias Transport = @Sendable (URL, Int) async throws -> Data
    private let configuration: CommunityCatalogConfiguration
    private let cacheDirectory: URL
    private let bundledSeed: Data?
    private let transport: Transport
    private let now: @Sendable () -> Date
    private var activeCatalog: CommunityCatalog?
    private var activePreviews = 0
    private let previewCacheBudget = 32 * 1_048_576

    init(configuration: CommunityCatalogConfiguration = .bundled(), cacheDirectory: URL? = nil, bundledSeed: Data? = nil,
         transport: @escaping Transport = CommunityHTTPClient.fetch, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.bundledSeed = bundledSeed
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WandelBar/Community", isDirectory: true)
        self.transport = transport
        self.now = now
    }

    func load() async throws -> CommunityCatalogSnapshot {
        guard Data(base64Encoded: configuration.publicKey)?.count == 32 else { throw CommunityCatalogError.unavailable }
        guard CommunityURLPolicy().allows(configuration.indexURL), configuration.indexURL.path == CommunityURLPolicy.root + "catalog.json" else { throw CommunityCatalogError.unsafeURL }
        let diskData = readCache()
        let seedData = bundledSeed ?? readBundledSeed()
        let disk = diskData.flatMap { try? CommunityCatalogVerifier.verify($0, configuration: configuration, now: now(), allowExpired: true) }
        let seed = seedData.flatMap { try? CommunityCatalogVerifier.verify($0, configuration: configuration, now: now(), allowExpired: true) }
        let usesSeed = seed != nil && (disk == nil || seed!.sequence > disk!.sequence)
        let cachedData = usesSeed ? seedData : diskData
        let cached = usesSeed ? seed : disk
        do {
            let data = try await transport(configuration.indexURL, CommunityCatalogVerifier.maximumIndexBytes)
            try Task.checkCancellation()
            let catalog = try CommunityCatalogVerifier.verify(data, configuration: configuration, now: now())
            if let cached {
                guard catalog.sequence >= cached.sequence, catalog.issuedAt >= cached.issuedAt,
                      catalog.sequence != cached.sequence || data == cachedData else { throw CommunityCatalogError.replay }
            }
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            activeCatalog = catalog
            cleanPreviewCache()
            return .init(catalog: catalog, isCached: false, status: "Verified catalogue · updated \(Date(timeIntervalSince1970: catalog.issuedAt).formatted(date: .abbreviated, time: .omitted))")
        } catch {
            try Task.checkCancellation()
            guard let cachedData, let catalog = try? CommunityCatalogVerifier.verify(cachedData, configuration: configuration, now: now()) else { throw error }
            activeCatalog = catalog
            cleanPreviewCache()
            return .init(catalog: catalog, isCached: true, status: "Refresh unavailable. Showing a verified \(usesSeed ? "bundled" : "cached") catalogue from \(Date(timeIntervalSince1970: catalog.issuedAt).formatted(date: .abbreviated, time: .omitted)); it may be out of date.")
        }
    }

    func download(_ entry: CommunityCatalogEntry) async throws -> URL {
        guard let catalog = activeCatalog, catalog.expiresAt > now().timeIntervalSince1970,
              catalog.entries.contains(entry) else { throw CommunityCatalogError.expired }
        let data = try await transport(entry.packageURL, entry.byteCount)
        try Task.checkCancellation()
        guard let current = activeCatalog, current.expiresAt > now().timeIntervalSince1970,
              current.entries.contains(entry) else { throw CommunityCatalogError.expired }
        try CommunityCatalogVerifier.verifyPackage(data, sha256: entry.sha256, byteCount: entry.byteCount)
        // The common import service owns all archive validation and the user confirms before commit.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wandelbar-presets")
        let packageData = entry.packageURL.pathExtension == "zip" ? try CommunityPackageAttachment.unwrap(data) : data
        try packageData.write(to: url, options: .atomic)
        do { try Task.checkCancellation() } catch { try? FileManager.default.removeItem(at: url); throw error }
        return url
    }

    func preview(_ entry: CommunityCatalogEntry) async throws -> Data {
        try requireActive(entry)
        guard let metadata = entry.preview else { throw CommunityCatalogError.unavailable }
        // Actor reentrancy permits many cards to request images; only two downloads may run.
        while activePreviews >= 2 {
            try await Task.sleep(for: .milliseconds(40))
            try requireActive(entry)
        }
        try Task.checkCancellation()
        try requireActive(entry)
        activePreviews += 1
        defer { activePreviews -= 1 }
        let path = previewDirectory.appendingPathComponent(metadata.sha256 + ".png")
        if let data = Self.readBoundedFile(path, limit: CommunityCatalogVerifier.maximumPreviewBytes),
           (try? CommunityCatalogVerifier.verifyPreview(data, metadata: metadata)) != nil {
            try requireActive(entry)
            try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: path.path)
            return data
        }
        try? FileManager.default.removeItem(at: path)
        let data = try await transport(metadata.url, metadata.byteCount)
        try Task.checkCancellation()
        try requireActive(entry)
        try CommunityCatalogVerifier.verifyPreview(data, metadata: metadata)
        // Cache failures must not prevent a verified image from being displayed.
        try? FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        try? data.write(to: path, options: .atomic)
        cleanPreviewCache()
        return data
    }

    private func requireActive(_ entry: CommunityCatalogEntry) throws {
        guard let catalog = activeCatalog, catalog.expiresAt > now().timeIntervalSince1970,
              catalog.entries.contains(entry) else { throw CommunityCatalogError.expired }
    }

    private var previewDirectory: URL { cacheDirectory.appendingPathComponent("previews", isDirectory: true) }
    private func cleanPreviewCache() {
        let manager = FileManager.default
        let names = Set(activeCatalog?.entries.compactMap { $0.preview.map { $0.sha256 + ".png" } } ?? [])
        let files = (try? manager.contentsOfDirectory(at: previewDirectory, includingPropertiesForKeys: nil)) ?? []
        var retained: [(URL, Int, Date)] = []
        for file in files {
            guard names.contains(file.lastPathComponent),
                  let attributes = try? manager.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  size.intValue <= CommunityCatalogVerifier.maximumPreviewBytes else {
                try? manager.removeItem(at: file)
                continue
            }
            retained.append((file, size.intValue, attributes[.modificationDate] as? Date ?? .distantPast))
        }
        var total = 0
        for (file, size, _) in retained.sorted(by: { $0.2 > $1.2 }) {
            total += size
            if total > previewCacheBudget { try? manager.removeItem(at: file) }
        }
    }

    private var cacheURL: URL { cacheDirectory.appendingPathComponent("catalog.json") }
    private func readCache() -> Data? { Self.readBoundedFile(cacheURL) }
    private func readBundledSeed() -> Data? {
        guard let url = CommunityResources.url(for: "catalog") else { return nil }
        return Self.readBoundedFile(url)
    }
    private static func readBoundedFile(_ url: URL, limit: Int = CommunityCatalogVerifier.maximumIndexBytes) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= limit,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1),
              data.count <= limit else { return nil }
        return data
    }
}

/// SwiftPM's Bundle.module accessor traps if its development bundle is missing.
/// Distributed apps use directly packaged resources and must never evaluate that fallback.
private enum CommunityResources {
    static func url(for name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Community") { return url }
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Community")
    }
}
