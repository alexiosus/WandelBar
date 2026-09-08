#!/usr/bin/env swift
import Foundation
import CryptoKit
import Darwin

// A separate Ed25519 catalogue key; never reuse an Apple/Developer ID signing identity.
struct ToolError: Error, CustomStringConvertible { let description: String; init(_ value: String) { description = value } }
let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) throws -> String {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else { throw ToolError("Missing \(name)") }
    return args[index + 1]
}
func file(_ name: String) throws -> URL { URL(fileURLWithPath: try option(name)).standardizedFileURL }
func boundedRead(_ url: URL, maximum: Int) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= maximum else { throw ToolError("Invalid or oversized file: \(url.path)") }
    let data = try Data(contentsOf: url)
    guard data.count <= maximum else { throw ToolError("File grew beyond limit") }
    return data
}
func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}
func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) }
func envelope(_ payload: Data, key: Curve25519.Signing.PrivateKey) throws -> Data {
    try json(["payload": payload.base64EncodedString(), "signature": key.signature(for: payload).base64EncodedString()])
}
func protectedKeyURL() throws -> URL {
    let key = try file("--key")
    let repository = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    let resolved = key.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(key.lastPathComponent)
    guard !resolved.path.hasPrefix(repository.path + "/") else { throw ToolError("Private key must be stored outside the repository") }
    return key
}
func validPayload(_ data: Data, allowExpired: Bool = false) throws {
    guard data.count <= 700_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["schemaVersion"] as? Int == 1, let client = object["minimumClientVersion"] as? Int, (1...2).contains(client),
          let sequence = object["sequence"] as? Int, sequence >= 1,
          let issued = object["issuedAt"] as? Double, let expires = object["expiresAt"] as? Double,
          issued.isFinite, expires.isFinite, issued <= Date().timeIntervalSince1970 + 300,
          (allowExpired || expires > Date().timeIntervalSince1970), expires > issued, expires - issued <= 30 * 86400,
          let entries = object["entries"] as? [[String: Any]], entries.count <= 200 else { throw ToolError("Invalid version, sequence, expiry or entry count") }
    var ids = Set<String>()
    for entry in entries {
        guard let id = entry["id"] as? String, id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              entry["sha256"] as? String == id, ids.insert(id).inserted,
              let size = entry["byteCount"] as? Int, (1...(32 * 1_048_576)).contains(size),
              let package = entry["packageURL"] as? String, validPackageURL(package, digest: id),
              let source = entry["sourceURL"] as? String, let url = URLComponents(string: source),
              url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.percentEncodedPath == url.path, url.path.hasPrefix("/alexiosus/WandelBar/discussions/"),
              let number = url.path.split(separator: "/").last, number.count <= 16,
              number.allSatisfy({ $0.isASCII && $0.isNumber }), url.path.split(separator: "/").count == 4,
              let tags = entry["tags"] as? [String], tags.count <= 8, Set(tags).count == tags.count else { throw ToolError("Invalid entry digest, size, URL or tags") }
        for (name, limit) in [("title", 100), ("author", 100), ("summary", 500)] {
            guard let text = entry[name] as? String, validText(text, limit: limit) else { throw ToolError("Invalid \(name)") }
        }
        guard tags.allSatisfy({ validText($0, limit: 30) }) else { throw ToolError("Invalid tag") }
    }
}
func validPackageURL(_ value: String, digest: String) -> Bool {
    if value == "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/packages/\(digest).wandelbar-presets" ||
       value == "https://raw.githubusercontent.com/alexiosus/WandelBar/main/Community/packages/\(digest).wandelbar-presets" { return true }
    return value.range(of: #"^https://github\.com/user-attachments/files/[1-9][0-9]{0,15}/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(zip|wandelbar-presets)$"#, options: .regularExpression) != nil
}

func validText(_ text: String, limit: Int) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit &&
    !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }
}

do {
    switch args.first {
    case "provision":
        let keyURL = try protectedKeyURL()
        guard !FileManager.default.fileExists(atPath: keyURL.path) else { throw ToolError("Key already exists; use sign for subsequent catalogues") }
        let configURL = try file("--config")
        if FileManager.default.fileExists(atPath: configURL.path),
           let existing = try JSONSerialization.jsonObject(with: boundedRead(configURL, maximum: 4096)) as? [String: Any],
           let publicKey = existing["publicKey"] as? String, !publicKey.isEmpty { throw ToolError("Configuration is already provisioned; key rotation requires an explicit app release") }
        let key = Curve25519.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // O_EXCL and 0600 prevent overwriting an existing key or ever creating a world-readable key.
        let descriptor = open(keyURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ToolError("Cannot create private key") }
        let bytesWritten = key.rawRepresentation.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard bytesWritten == 32 else { try? FileManager.default.removeItem(at: keyURL); throw ToolError("Could not write complete key") }
        try write(json(["publicKey": key.publicKey.rawRepresentation.base64EncodedString(), "indexURL": "https://raw.githubusercontent.com/alexiosus/WandelBar/master/Community/catalog.json", "minimumSequence": 1]), to: configURL)
        let now = floor(Date().timeIntervalSince1970)
        let payload = try json(["schemaVersion": 1, "minimumClientVersion": 1, "sequence": 1, "issuedAt": now, "expiresAt": now + 30 * 86400, "entries": []] as [String: Any])
        let signed = try envelope(payload, key: key)
        try write(signed, to: file("--output"))
        try write(signed, to: configURL.deletingLastPathComponent().appendingPathComponent("catalog.json"))
        print("Created private key outside the repository, pinned public configuration and signed empty catalogue. Nothing was uploaded.")
    case "sign":
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: boundedRead(protectedKeyURL(), maximum: 32))
        let payload = try boundedRead(file("--input"), maximum: 700_000)
        try validPayload(payload)
        try write(envelope(payload, key: key), to: file("--output"))
        print("Signed catalogue. Increment sequence for every change; publish only after review.")
    case "check-key":
        let keyURL = try protectedKeyURL()
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw ToolError("Private key permissions must be owner-only") }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: boundedRead(keyURL, maximum: 32))
        let config = try JSONSerialization.jsonObject(with: boundedRead(file("--config"), maximum: 4096)) as? [String: Any]
        guard config?["publicKey"] as? String == key.publicKey.rawRepresentation.base64EncodedString() else { throw ToolError("Private key does not match pinned configuration") }
        print("Private key matches pinned public configuration; permissions are owner-only.")
    case "verify":
        let config = try JSONSerialization.jsonObject(with: boundedRead(file("--config"), maximum: 4096)) as? [String: Any]
        guard let publicKey = config?["publicKey"] as? String, let keyData = Data(base64Encoded: publicKey),
              let envelope = try JSONSerialization.jsonObject(with: boundedRead(file("--input"), maximum: 1_048_576)) as? [String: String],
              let payloadString = envelope["payload"], let payload = Data(base64Encoded: payloadString),
              let signatureString = envelope["signature"], let signature = Data(base64Encoded: signatureString),
              try Curve25519.Signing.PublicKey(rawRepresentation: keyData).isValidSignature(signature, for: payload) else { throw ToolError("Invalid signature") }
        try validPayload(payload, allowExpired: args.contains("--allow-expired"))
        print("Valid pinned signature and catalogue payload.")
    default:
        throw ToolError("Usage:\n  swift Scripts/catalog_sign.swift provision --key OUTSIDE_REPO --config CONFIG.json --output Community/catalog.json\n  swift Scripts/catalog_sign.swift sign --key OUTSIDE_REPO --input payload.json --output Community/catalog.json\n  swift Scripts/catalog_sign.swift verify --config CONFIG.json --input Community/catalog.json")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
