import Foundation
import Testing
@testable import WandelBar

@Test func digestUsesTheWholeInputAndIsFilesystemSafe() {
    let longPrefix = String(repeating: "shared-directory/", count: 20)
    let first = FileCacheKey.digest([longPrefix + "first.jpg"])
    let second = FileCacheKey.digest([longPrefix + "second.jpg"])

    #expect(first != second)
    #expect(first.count == 64)
    #expect(first.allSatisfy { $0.isHexDigit })
    #expect(!first.contains("/"))
}

@Test func sourceSignatureChangesWhenFileChanges() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("wallpaper.png")
    try Data("one".utf8).write(to: file)
    let first = FileCacheKey.sourceSignature(for: file, pixelSize: CGSize(width: 100, height: 100))

    try Data("a different size".utf8).write(to: file)
    let second = FileCacheKey.sourceSignature(for: file, pixelSize: CGSize(width: 100, height: 100))

    #expect(first != second)
}

@Test func sourceSignatureDetectsSameSizeContentWithPreservedModificationDate() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let file = directory.appendingPathComponent("wallpaper.png")
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try Data("first".utf8).write(to: file)
    try fileManager.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
    let first = FileCacheKey.sourceSignature(for: file, pixelSize: CGSize(width: 100, height: 100))

    try Data("other".utf8).write(to: file)
    try fileManager.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
    let second = FileCacheKey.sourceSignature(for: file, pixelSize: CGSize(width: 100, height: 100))

    #expect(first != second)
}
