import AppKit
import SwiftUI

struct TextureManagementView: View {
    @ObservedObject var model: MenuBarPopoverModel
    @State private var target: TextureAsset?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unused Textures").font(.title2.bold())
            Text("Only custom textures unused by presets, Undo and all Space settings appear here.")
                .font(.callout).foregroundStyle(.secondary)
            if model.unusedTextures.isEmpty {
                ContentUnavailableView("Nothing to clean up", systemImage: "checkmark.circle",
                    description: Text("Your custom textures are in use, or your library is empty."))
            } else {
                List(model.unusedTextures) { texture in
                    HStack {
                        Text(texture.name)
                        Spacer()
                        Button("Delete…", role: .destructive) { target = texture }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(20).frame(width: 480, height: 370)
        .alert("Delete unused texture?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            Button("Cancel", role: .cancel) { target = nil }
            Button("Delete", role: .destructive) {
                guard let target else { return }
                do { try model.removeUnusedTexture(target.id); error = nil }
                catch { self.error = error.localizedDescription }
                self.target = nil
            }
        } message: { Text("Delete “\(target?.name ?? "")” from this Mac? Usage will be checked again before removal.") }
    }
}

struct PresetShareResultView: View {
    let result: PresetShareResult
    @State private var copied = false
    @State private var draftOpened = false
    @State private var browserError = false

    private var previewHeight: CGFloat {
        let height = result.previewURLs.reduce(CGFloat(0)) { total, url in
            guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return total }
            return total + 512 * image.size.height / image.size.width + 12
        }
        return min(340, max(140, height))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ready to Share").font(.title2.bold())
            Text("Open the draft, drag all attachments into the editor together, wait for uploads, then publish.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(result.previewURLs, id: \.self) { url in
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFit()
                        }
                    }
                }
            }.frame(height: previewHeight)
            ShareAttachmentDragView(urls: result.attachmentURLs, label: "Drag all attachments (\(result.attachmentURLs.count) files)")
                .frame(height: 44)
            if draftOpened {
                Text("The post text is also copied. If GitHub opens an empty editor, paste it with ⌘V. Drop the attachments at the end of the post and wait for uploads to finish.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if browserError {
                Text("Could not open your browser. The post text has been copied; open Preset Exchange on GitHub to continue.")
                    .font(.caption).foregroundStyle(.red)
            }
            if result.usesCurrentWallpaper {
                Text("These previews include your current wallpaper.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Files are temporary. Use Show Files to copy them elsewhere if you want to keep them.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Dragging uploads the files to GitHub. Nothing is published until you click Start discussion. Share only textures you can redistribute.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show Files") { NSWorkspace.shared.activateFileViewerSelecting(result.attachmentURLs) }
                Button(copied ? "Copied" : "Copy Post") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.markdown, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Prepare GitHub Post") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.markdown, forType: .string)
                    copied = true
                    let url = DiscussionDraft.url(title: result.title, body: result.markdown) ?? AppInformation.newDiscussion
                    browserError = !NSWorkspace.shared.open(url)
                    draftOpened = !browserError
                }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 560)
    }
}


/// A native multi-file drag exposes actual file URLs to browsers, as Finder does.
private struct ShareAttachmentDragView: NSViewRepresentable {
    let urls: [URL]
    let label: String
    func makeNSView(context: Context) -> ShareAttachmentDragSource { ShareAttachmentDragSource() }
    func updateNSView(_ view: ShareAttachmentDragSource, context: Context) { view.urls = urls; view.label = label }
}

private final class ShareAttachmentDragSource: NSView, NSDraggingSource {
    var urls: [URL] = [] { didSet { needsDisplay = true } }
    var label: String = "Drag attachments" { didSet { needsDisplay = true } }
    private var mouseOrigin: NSPoint?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.stroke()
        let text = label
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        setAccessibilityLabel(text)
        setAccessibilityHelp("Alternatively, use Show Files to select all attachments together in Finder.")
    }

    override func mouseDown(with event: NSEvent) { mouseOrigin = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { mouseOrigin = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseOrigin,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 4 else { return }
        mouseOrigin = nil
        let point = convert(event.locationInWindow, from: nil)
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        let writers = ShareFileDrag.items(for: files)
        let items = files.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: writers[index])
            item.setDraggingFrame(NSRect(x: point.x + CGFloat(index * 5), y: point.y, width: 32, height: 32),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        guard !items.isEmpty else { return }
        let session = beginDraggingSession(with: items, event: event, source: self)
        ShareFileDrag.addFileList(files, to: session.draggingPasteboard)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
