import AppKit

struct PresetPreviewContext: Sendable {
    let sourceURL: URL
    let display: DisplaySnapshot
    let storedDesktop: StoredDesktop
    let sourceIdentity: String

    var cacheKey: String {
        let pixelSize = display.pixelSize
        let sourceSignature = FileCacheKey.sourceSignature(
            for: sourceURL,
            pixelSize: pixelSize
        )
        let components: [String] = [
            sourceIdentity,
            sourceSignature,
            display.id,
            String(Double(pixelSize.width)),
            String(Double(pixelSize.height)),
            String(storedDesktop.imageScaling ?? -1),
            String(storedDesktop.allowClipping ?? true),
            storedDesktop.fillColorData?.base64EncodedString() ?? "default-fill"
        ]
        return FileCacheKey.digest(components)
    }
}

