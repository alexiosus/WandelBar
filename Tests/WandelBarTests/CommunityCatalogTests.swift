import Foundation
import AppKit
import CryptoKit
import Testing
@testable import WandelBar

private let catalogueNow = Date(timeIntervalSince1970: 1_800_000_000)
private func signedCatalogue(key: Curve25519.Signing.PrivateKey, sequence: Int = 1, entries: [[String: Any]] = [], expires: TimeInterval = 3600) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "minimumClientVersion": 1, "sequence": sequence, "issuedAt": catalogueNow.timeIntervalSince1970 - 60, "expiresAt": catalogueNow.timeIntervalSince1970 + expires, "entries": entries], options: .sortedKeys)
    return try JSONSerialization.data(withJSONObject: ["payload": payload.base64EncodedString(), "signature": key.signature(for: payload).base64EncodedString()])
}
private func catalogConfiguration(_ key: Curve25519.Signing.PrivateKey) -> CommunityCatalogConfiguration {
    .init(publicKey: key.publicKey.rawRepresentation.base64EncodedString())
}

@Test func catalogueRejectsTamperingAndUntrustedSigner() throws {
    let key = Curve25519.Signing.PrivateKey()
    let config = catalogConfiguration(key)
    let valid = try signedCatalogue(key: key)
    #expect(try CommunityCatalogVerifier.verify(valid, configuration: config, now: catalogueNow).entries.isEmpty)
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verify(signedCatalogue(key: .init()), configuration: config, now: catalogueNow) }
    var envelope = try JSONSerialization.jsonObject(with: valid) as! [String: String]
    envelope["payload"] = Data("{}".utf8).base64EncodedString()
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verify(JSONSerialization.data(withJSONObject: envelope), configuration: config, now: catalogueNow) }
}

@Test func catalogueRejectsExpiredOversizedUnsupportedAndUnsafeEntries() throws {
    let key = Curve25519.Signing.PrivateKey()
    let config = catalogConfiguration(key)
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verify(signedCatalogue(key: key, expires: -1), configuration: config, now: catalogueNow) }
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verify(Data(repeating: 0, count: 1_048_577), configuration: config, now: catalogueNow) }
    let badEntry: [String: Any] = ["id": String(repeating: "a", count: 64), "title": "Test", "author": "Author", "summary": "Example", "tags": [], "sourceURL": "https://github.com/alexiosus/WandelBar/discussions/1", "packageURL": "https://evil.example/a", "sha256": String(repeating: "a", count: 64), "byteCount": 10]
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verify(signedCatalogue(key: key, entries: [badEntry]), configuration: config, now: catalogueNow) }
}

@Test func catalogueURLPolicyAppliesToEveryRedirect() {
    let policy = CommunityURLPolicy()
    #expect(policy.allows(URL(string: "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/catalog.json")!))
    for value in ["http://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/catalog.json", "https://raw.githubusercontent.com.evil.test/alexiosus/WandelBar/master/Community/catalog.json", "https://user@raw.githubusercontent.com/alexiosus/WandelBar/master/Community/catalog.json", "https://raw.githubusercontent.com/alexiosus/Other/master/Community/catalog.json", "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/../secret", "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/catalog.json?token=x", "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/%63atalog.json"] {
        #expect(!policy.allows(URL(string: value)!))
        #expect(!policy.allowsRedirect(to: URL(string: value)!, count: 1))
    }
    #expect(!policy.allowsRedirect(to: URL(string: "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/catalog.json")!, count: 4))
}

@Test func catalogueDownloadRejectsWrongDigestAndSize() throws {
    let data = Data("abc".utf8)
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verifyPackage(data, sha256: String(repeating: "0", count: 64), byteCount: 3) }
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verifyPackage(data, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", byteCount: 4) }
    try CommunityCatalogVerifier.verifyPackage(data, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", byteCount: 3)
}

@Test func catalogueConstructionDoesNotFetchAndCacheIsReverified() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = CatalogFetchCounter()
    let envelope = try signedCatalogue(key: key)
    let service = CommunityCatalogService(configuration: catalogConfiguration(key), cacheDirectory: directory, transport: { _, _ in await counter.increment(); return envelope }, now: { catalogueNow })
    #expect(await counter.count == 0)
    let fresh = try await service.load()
    #expect(!fresh.isCached)
    let offline = CommunityCatalogService(configuration: catalogConfiguration(key), cacheDirectory: directory, transport: { _, _ in throw URLError(.notConnectedToInternet) }, now: { catalogueNow })
    #expect(try await offline.load().isCached)
    let untrusted = CommunityCatalogService(configuration: catalogConfiguration(.init()), cacheDirectory: directory, transport: { _, _ in throw URLError(.notConnectedToInternet) }, now: { catalogueNow })
    await #expect(throws: (any Error).self) { try await untrusted.load() }
    let replay = CommunityCatalogService(configuration: catalogConfiguration(key), cacheDirectory: directory, transport: { _, _ in try signedCatalogue(key: key, sequence: 0) }, now: { catalogueNow })
    #expect(try await replay.load().isCached)
}
private actor CatalogFetchCounter {
    var count = 0
    func increment() { count += 1 }
}

@Test func catalogueOfflineUsesVerifiedBundledSeedAndRejectsExpiredSeed() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let seed = try signedCatalogue(key: key)
    let offline = CommunityCatalogService(configuration: catalogConfiguration(key), cacheDirectory: directory, bundledSeed: seed, transport: { _, _ in throw URLError(.notConnectedToInternet) }, now: { catalogueNow })
    let result = try await offline.load()
    #expect(result.status.contains("bundled"))
    #expect(result.catalog.entries.isEmpty)
    let expired = CommunityCatalogService(configuration: catalogConfiguration(key), cacheDirectory: directory, bundledSeed: try signedCatalogue(key: key, expires: -1), transport: { _, _ in throw URLError(.notConnectedToInternet) }, now: { catalogueNow })
    await #expect(throws: (any Error).self) { try await expired.load() }
}

@Test func catalogueDownloadRechecksExpiryAfterNetwork() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let entry: [String: Any] = ["id": digest, "title": "Test", "author": "Author", "summary": "Example", "tags": ["test"], "sourceURL": "https://github.com/alexiosus/WandelBar/discussions/1", "packageURL": "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/packages/\(digest).wandelbar-presets", "sha256": digest, "byteCount": 3]
    let envelope = try signedCatalogue(key: key, entries: [entry])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = CatalogTestClock()
    let service = CommunityCatalogService(configuration: catalogConfiguration(key), cacheDirectory: directory, transport: { url, _ in
        if url.lastPathComponent == "catalog.json" { return envelope }
        clock.advance()
        return Data("abc".utf8)
    }, now: { clock.date })
    let snapshot = try await service.load()
    await #expect(throws: (any Error).self) { try await service.download(snapshot.catalog.entries[0]) }
}
private final class CatalogTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var advanced = false
    var date: Date { lock.lock(); defer { lock.unlock() }; return catalogueNow.addingTimeInterval(advanced ? 4000 : 0) }
    func advance() { lock.lock(); advanced = true; lock.unlock() }
}

@Test func catalogueRejectsUnsupportedVersionsAndExcessiveSignedCounts() throws {
    let key = Curve25519.Signing.PrivateKey()
    let configuration = catalogConfiguration(key)
    let valid = try signedCatalogue(key: key)
    let original = try JSONSerialization.jsonObject(with: valid) as! [String: String]
    let payload = try JSONSerialization.jsonObject(with: Data(base64Encoded: original["payload"]!)!) as! [String: Any]
    let modifications: [(String, Any)] = [("schemaVersion", 2), ("minimumClientVersion", 3), ("sequence", -1), ("entries", Array(repeating: [:] as [String: Any], count: 201)), ("expiresAt", catalogueNow.timeIntervalSince1970 + 31 * 86400), ("issuedAt", catalogueNow.timeIntervalSince1970 + 301)]
    for (field, value) in modifications {
        var changed = payload
        changed[field] = value
        let data = try JSONSerialization.data(withJSONObject: changed)
        let signed = try JSONSerialization.data(withJSONObject: ["payload": data.base64EncodedString(), "signature": key.signature(for: data).base64EncodedString()])
        #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verify(signed, configuration: configuration, now: catalogueNow) }
    }
}

@Test func catalogueTamperedDiskCacheDoesNotEnableOfflineGallery() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try signedCatalogue(key: .init()).write(to: directory.appendingPathComponent("catalog.json"))
    let service = CommunityCatalogService(configuration: catalogConfiguration(key), cacheDirectory: directory, transport: { _, _ in throw URLError(.notConnectedToInternet) }, now: { catalogueNow })
    await #expect(throws: (any Error).self) { try await service.load() }
    try Data(repeating: 0, count: 1_048_577).write(to: directory.appendingPathComponent("catalog.json"))
    await #expect(throws: (any Error).self) { try await service.load() }
}

@Test func attachmentRedirectsStayBoundToApprovedFileAndRepository() {
    let original = URL(string: "https://github.com/user-attachments/files/31951170/Presets.zip")!
    let index = URL(string: "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/catalog.json")!
    let cdn = "https://objects.githubusercontent.com/github-production-repository-file-5c1aeb/1341390246/31951170?X-Amz-Signature=test"
    let policy = CommunityURLPolicy()
    #expect(CommunityURLPolicy.attachmentID(original) == "31951170")
    #expect(policy.allowsResponse(URL(string: cdn)!, from: original, count: 1))
    #expect(!policy.allowsResponse(original, from: index, count: 1))
    #expect(!policy.allowsResponse(URL(string: cdn)!, from: original, count: 4))
    for bad in [cdn.replacingOccurrences(of: "31951170", with: "12"), cdn.replacingOccurrences(of: "1341390246", with: "1"),
                cdn.replacingOccurrences(of: "https:", with: "http:"), cdn.replacingOccurrences(of: "objects.githubusercontent.com", with: "user@objects.githubusercontent.com"),
                "https://evil.test/file.zip", original.absoluteString + "?token=x"] {
        #expect(!policy.allowsResponse(URL(string: bad)!, from: original, count: 1))
    }
}

@Test func signedCatalogueAcceptsAttachmentButRejectsUnsignedURLParameters() throws {
    let key = Curve25519.Signing.PrivateKey()
    let hash = String(repeating: "a", count: 64)
    var entry: [String: Any] = ["id": hash, "sha256": hash, "title": "Example", "author": "Author", "summary": "Example", "tags": [],
        "sourceURL": "https://github.com/alexiosus/WandelBar/discussions/4", "packageURL": "https://github.com/user-attachments/files/31951170/Presets.zip", "byteCount": 100]
    #expect(try CommunityCatalogVerifier.verify(signedCatalogue(key: key, entries: [entry]), configuration: catalogConfiguration(key), now: catalogueNow).entries.count == 1)
    entry["packageURL"] = "https://github.com/user-attachments/files/31951170/Presets.zip?token=x"
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verify(signedCatalogue(key: key, entries: [entry]), configuration: catalogConfiguration(key), now: catalogueNow) }
}

@Test func attachmentUnwrapAcceptsOnlyOneRootPackage() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let contents = directory.appendingPathComponent("contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let package = Data("inner package bytes validated later by import".utf8)
    try package.write(to: contents.appendingPathComponent("Presets.wandelbar-presets"))
    let zip = directory.appendingPathComponent("attachment.zip")
    let archive = SystemPresetPackageArchive()
    try archive.createSharingArchive(from: contents, at: zip, allowedFileNames: ["Presets.wandelbar-presets"])
    #expect(try CommunityPackageAttachment.unwrap(Data(contentsOf: zip)) == package)
    try Data("extra".utf8).write(to: contents.appendingPathComponent("extra.txt"))
    try archive.createSharingArchive(from: contents, at: zip, allowedFileNames: ["Presets.wandelbar-presets", "extra.txt"])
    #expect(throws: (any Error).self) { try CommunityPackageAttachment.unwrap(Data(contentsOf: zip)) }
    #expect(throws: (any Error).self) { try CommunityPackageAttachment.unwrap(Data("not a zip".utf8)) }
}

@Test func downloadVerifiesWrapperBeforeUnwrapping() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let data = Data("not a ZIP".utf8)
    let hash = String(repeating: "a", count: 64)
    let entry: [String: Any] = ["id": hash, "sha256": hash, "title": "Example", "author": "Author", "summary": "Example", "tags": [],
        "sourceURL": "https://github.com/alexiosus/WandelBar/discussions/4", "packageURL": "https://github.com/user-attachments/files/31951170/Presets.zip", "byteCount": data.count]
    let envelope = try signedCatalogue(key: key, entries: [entry])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = CommunityCatalogService(configuration: catalogConfiguration(key), cacheDirectory: directory, transport: { url, _ in url.pathExtension == "json" ? envelope : data }, now: { catalogueNow })
    let snapshot = try await service.load()
    do {
        _ = try await service.download(snapshot.catalog.entries[0])
        Issue.record("Modified wrapper was accepted")
    } catch CommunityCatalogError.digestMismatch {
        // Authentication of outer bytes takes precedence over any archive parsing.
    } catch {
        Issue.record("Expected digest mismatch before ZIP parsing")
    }
}

@Test @MainActor func publishedDiscussionAttachmentsPassRealImportValidation() async throws {
    guard ProcessInfo.processInfo.environment["WANDELBAR_COMMUNITY_LIVE_QA"] == "1" else { return }
    let textures = try TextureStoreFixture()
    defer { textures.cleanUp() }
    let suite = "WandelBarTests.LiveCommunity.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let service = PresetPackageService(presetStore: store, textureStore: textures.store, archive: SystemPresetPackageArchive())
    for (number, name) in [(31951170, "Acrylic"), (31950882, "Waves")] {
        let url = URL(string: "https://github.com/user-attachments/files/\(number)/Presets.zip")!
        let data = try await CommunityHTTPClient.fetch(url, limit: CommunityCatalogVerifier.maximumPackageBytes)
        let inner = try CommunityPackageAttachment.unwrap(data)
        let path = textures.directory.appendingPathComponent("\(number).wandelbar-presets")
        try inner.write(to: path)
        let preview = try await service.prepareImport(from: path)
        #expect(preview.presets.map(\.sourceName) == [name])
        service.discardImport(preview)
    }
    #expect(store.userPresets.isEmpty)
}

@Test @MainActor func liveCommunityCatalogueDownloadsApprovedEntries() async throws {
    guard ProcessInfo.processInfo.environment["WANDELBAR_COMMUNITY_LIVE_QA"] == "1" else { return }
    let textures = try TextureStoreFixture()
    defer { textures.cleanUp() }
    let suite = "WandelBarTests.LiveCatalogue.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let library = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let importer = PresetPackageService(presetStore: library, textureStore: textures.store, archive: SystemPresetPackageArchive())
    let catalogue = CommunityCatalogService(cacheDirectory: textures.directory.appendingPathComponent("catalogue-cache"))
    let snapshot = try await catalogue.load()
    #expect(snapshot.catalog.minimumClientVersion == 2)
    #expect(Set(snapshot.catalog.entries.map(\.title)).isSuperset(of: ["Acrylic", "Waves"]))
    for entry in snapshot.catalog.entries where ["Acrylic", "Waves"].contains(entry.title) {
        let file = try await catalogue.download(entry)
        defer { try? FileManager.default.removeItem(at: file) }
        let preview = try await importer.prepareImport(from: file)
        #expect(preview.presets.count == 1)
        importer.discardImport(preview)
    }
    #expect(library.userPresets.isEmpty)
}

private func previewFixture() throws -> (Data, CommunityPreviewMetadata) {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.setColor(.red, atX: 0, y: 0)
    bitmap.setColor(.blue, atX: 1, y: 0)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (data, CommunityPreviewMetadata(url: URL(string: "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/previews/\(hash).png")!, sha256: hash, byteCount: data.count, width: 2, height: 1))
}

private func entryWithPreview(_ metadata: CommunityPreviewMetadata) throws -> [String: Any] {
    let hash = String(repeating: "b", count: 64)
    return ["id": hash, "sha256": hash, "title": "Example", "author": "Author", "summary": "Example", "tags": [],
        "sourceURL": "https://github.com/alexiosus/WandelBar/discussions/4", "packageURL": "https://github.com/user-attachments/files/31951170/Presets.zip", "byteCount": 100,
        "preview": try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata))]
}

@Test func communityPreviewRejectsChangedBytesAndMisstatedDimensions() throws {
    let (data, metadata) = try previewFixture()
    try CommunityCatalogVerifier.verifyPreview(data, metadata: metadata)
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verifyPreview(Data("broken".utf8), metadata: metadata) }
    let wrong = CommunityPreviewMetadata(url: metadata.url, sha256: metadata.sha256, byteCount: metadata.byteCount, width: 3, height: 1)
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verifyPreview(data, metadata: wrong) }
    let unsafe = CommunityPreviewMetadata(url: URL(string: "https://evil.test/image.png")!, sha256: metadata.sha256, byteCount: metadata.byteCount, width: 2, height: 1)
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verifyPreviewMetadata(unsafe) }
    let large = CommunityPreviewMetadata(url: metadata.url, sha256: metadata.sha256, byteCount: 8 * 1_048_576 + 1, width: 2, height: 1)
    #expect(throws: (any Error).self) { try CommunityCatalogVerifier.verifyPreviewMetadata(large) }
    let index = CommunityCatalogConfiguration(publicKey: "").indexURL
    #expect(!CommunityURLPolicy().allowsResponse(metadata.url, from: index, count: 1))
}

@Test func communityPreviewCacheIsUsableOfflineAndAlwaysReverified() async throws {
    let (data, metadata) = try previewFixture()
    let key = Curve25519.Signing.PrivateKey()
    let envelope = try signedCatalogue(key: key, entries: [entryWithPreview(metadata)])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let online = CommunityCatalogService(configuration: catalogConfiguration(key), cacheDirectory: directory,
        transport: { url, _ in url.pathExtension == "png" ? data : envelope }, now: { catalogueNow })
    let first = try await online.load()
    #expect(try await online.preview(first.catalog.entries[0]) == data)
    let offline = CommunityCatalogService(configuration: catalogConfiguration(key), cacheDirectory: directory,
        transport: { _, _ in throw URLError(.notConnectedToInternet) }, now: { catalogueNow })
    let cached = try await offline.load()
    #expect(try await offline.preview(cached.catalog.entries[0]) == data)
    try Data("tampered cache".utf8).write(to: directory.appendingPathComponent("previews/\(metadata.sha256).png"))
    await #expect(throws: (any Error).self) { try await offline.preview(cached.catalog.entries[0]) }
}

@Test func liveCommunityPreviewsAreSignedAndDecodable() async throws {
    guard ProcessInfo.processInfo.environment["WANDELBAR_COMMUNITY_PREVIEW_QA"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = CommunityCatalogService(cacheDirectory: directory)
    let snapshot = try await service.load()
    let entries = snapshot.catalog.entries.filter { ["Acrylic", "Waves"].contains($0.title) }
    #expect(entries.count == 2)
    for entry in entries {
        let metadata = try #require(entry.preview)
        let data = try await service.preview(entry)
        try CommunityCatalogVerifier.verifyPreview(data, metadata: metadata)
        #expect(metadata.width == 2160)
    }
}
