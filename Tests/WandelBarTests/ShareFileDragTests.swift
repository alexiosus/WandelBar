import AppKit
import Testing
@testable import WandelBar

@Test @MainActor func fileDragContainsTheWholeSelectionWithoutTextOrHTML() throws {
    let urls = [URL(fileURLWithPath: "/tmp/Share files/Presets.zip"), URL(fileURLWithPath: "/tmp/Share files/Preview-1.png")]
    let items = ShareFileDrag.items(for: urls)
    #expect(items.count == 2)
    let pasteboard = NSPasteboard(name: .init("WandelBar.DragTest." + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    #expect(pasteboard.writeObjects(items))
    ShareFileDrag.addFileList(urls, to: pasteboard)
    #expect(pasteboard.propertyList(forType: ShareFileDrag.filenamesType) as? [String] == urls.map(\.path))
    let restored = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    #expect(restored == urls)
    #expect(pasteboard.string(forType: .string) == nil)
    #expect(pasteboard.string(forType: .html) == nil)
}

@Test @MainActor func dockPresenceRestoresOriginalPolicyAfterWindowReplacement() {
    let presence = DialogDockPresence()
    var changes: [NSApplication.ActivationPolicy] = []
    presence.show(current: .accessory, set: { changes.append($0) })
    presence.show(current: .regular, set: { changes.append($0) })
    presence.restore(set: { changes.append($0) })
    presence.restore(set: { changes.append($0) })
    #expect(changes == [.regular, .accessory])
}

@Test @MainActor func sharingDragsDownloadBeforeImagesInBothFileRepresentations() throws {
    let directory = URL(fileURLWithPath: "/tmp/WandelBar Share")
    let previews = [directory.appendingPathComponent("Preview-1.png"), directory.appendingPathComponent("Preview-2.png")]
    let result = PresetShareResult(directory: directory, previewURLs: previews, markdown: "Post")
    let expected = [directory.appendingPathComponent("Presets.zip")] + previews
    #expect(result.attachmentURLs == expected)
    let pasteboard = NSPasteboard(name: .init("WandelBar.DragOrder." + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    #expect(pasteboard.writeObjects(ShareFileDrag.items(for: result.attachmentURLs)))
    ShareFileDrag.addFileList(result.attachmentURLs, to: pasteboard)
    #expect(pasteboard.propertyList(forType: ShareFileDrag.filenamesType) as? [String] == expected.map(\.path))
    #expect((pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) == expected)
}
