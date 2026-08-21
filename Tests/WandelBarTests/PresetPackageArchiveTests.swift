import Foundation
import Testing
@testable import WandelBar

@Test func systemArchiveCreatesListsAndExtractsOnePortableFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("source", isDirectory: true)
    let output = root.appendingPathComponent("Shared.wandelbar-presets")
    let extracted = root.appendingPathComponent("extracted", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: source.appendingPathComponent("textures", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
    try Data([1, 2, 3]).write(to: source.appendingPathComponent("textures/abc.png"))

    let archive = SystemPresetPackageArchive()
    try archive.createArchive(from: source, at: output)
    #expect(Set(try archive.listEntries(in: output)) == [
        "manifest.json", "textures/", "textures/abc.png"
    ])
    try archive.extractArchive(at: output, to: extracted)
    #expect(try Data(contentsOf: extracted.appendingPathComponent("manifest.json")) == Data("{}".utf8))
}
