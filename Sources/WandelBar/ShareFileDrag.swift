import AppKit

@MainActor
enum ShareFileDrag {
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static func items(for urls: [URL]) -> [NSPasteboardItem] {
        urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
    }

    static func addFileList(_ urls: [URL], to pasteboard: NSPasteboard) {
        // The legacy path list belongs to the pasteboard, not an individual item
        // (NSPasteboardItem only accepts UTIs). Keep modern file URL items intact.
        pasteboard.addTypes([filenamesType], owner: nil)
        pasteboard.setPropertyList(urls.map(\.path), forType: filenamesType)
    }

}

@MainActor
final class DialogDockPresence {
    private var previous: NSApplication.ActivationPolicy?
    func show(current: NSApplication.ActivationPolicy, set: (NSApplication.ActivationPolicy) -> Void) {
        guard previous == nil else { return }
        previous = current
        if current != .regular { set(.regular) }
    }
    func restore(set: (NSApplication.ActivationPolicy) -> Void) {
        guard let previous else { return }
        self.previous = nil
        set(previous)
    }
}
