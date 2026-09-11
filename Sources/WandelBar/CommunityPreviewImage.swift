import SwiftUI
import ImageIO

/// Lives only inside a visible lazy gallery card. No background catalogue image fetching.
struct CommunityPreviewImage: View {
    let entry: CommunityCatalogEntry
    let service: CommunityCatalogService
    @State private var image: NSImage?
    @State private var expanded = false
    @State private var enlargedImage: NSImage?

    private var thumbnailAspectRatio: CGFloat {
        guard let preview = entry.preview else { return 2 }
        return max(1.9, CGFloat(preview.width) / CGFloat(preview.height))
    }

    private var enlargedHeight: CGFloat {
        guard let preview = entry.preview else { return 400 }
        return min(680, max(320, CGFloat(preview.height) * 720 / CGFloat(preview.width) + 100))
    }

    var body: some View {
        Group {
            if let image {
                Button { expanded = true } label: {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .help("Enlarge generated preview")
                .accessibilityLabel("Generated preview of \(entry.title)")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "menubar.rectangle").font(.largeTitle)
                    Text("Preview unavailable").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(thumbnailAspectRatio, contentMode: .fit)
        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: entry.preview?.sha256) {
            image = nil
            guard entry.preview != nil else { return }
            do {
                let data = try await service.preview(entry)
                try Task.checkCancellation()
                image = Self.thumbnail(data, maximumPixels: 720)
            } catch { /* Optional artwork never blocks import or offline browsing. */ }
        }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 12) {
                Text(entry.title).font(.headline)
                if let displayed = enlargedImage ?? image {
                    ScrollView { Image(nsImage: displayed).resizable().scaledToFit().frame(maxWidth: .infinity) }
                }
                Button("Done") { expanded = false }.keyboardShortcut(.defaultAction)
            }.padding(20).frame(width: 760, height: enlargedHeight)
            .task {
                if let data = try? await service.preview(entry), !Task.isCancelled { enlargedImage = NSImage(data: data) }
            }
            .onDisappear { enlargedImage = nil }
        }
        .onDisappear { image = nil; enlargedImage = nil }
    }

    private static func thumbnail(_ data: Data, maximumPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
