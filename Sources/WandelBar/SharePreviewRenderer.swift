import AppKit
import CoreText

struct SharePreviewItem: Sendable {
    let name: String
    let settings: WallpaperEffectSettings
    let textureURL: URL?
}

/// Current wallpaper is accepted only through an explicitly selected sharing context.
/// No screen capture is performed.
enum SharePreviewRenderer {
    static func render(_ items: [SharePreviewItem], wallpaper: PresetPreviewContext? = nil) throws -> CGImage {
        let scale: CGFloat = 3
        let height = items.count * 200 + max(0, items.count - 1) * 16 + 32
        guard !items.isEmpty, items.count <= 6,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 2160, height: height * 3,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WallpaperRendererError.cannotCreateBitmap
        }
        context.scaleBy(x: scale, y: scale)
        context.clear(CGRect(x: 0, y: 0, width: 720, height: height))
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            // Use the full-resolution bundled source directly for the sample strip,
            // rather than resizing a previously downsampled thumbnail.
            // Effects and text render at Retina scale, not by upscaling the final PNG.
            let image: CGImage
            if let wallpaper {
                image = try WallpaperRenderer().renderPreview(
                    sourceURL: wallpaper.sourceURL, display: wallpaper.display,
                    desktopOptions: wallpaper.storedDesktop.renderOptions,
                    settings: item.settings, textureURL: item.textureURL,
                    size: CGSize(width: 720, height: 200), backingScaleFactor: scale, menuBarHeightPoints: 24)
            } else {
                let desktop = try WallpaperRenderer().renderSamplePreview(
                    settings: item.settings, textureURL: item.textureURL,
                    menuBarHeightPoints: 24, size: CGSize(width: 720, height: 256),
                    backingScaleFactor: scale)
                guard let crop = desktop.cropping(to: CGRect(x: 0, y: 0, width: 2160, height: 600)) else {
                    throw WallpaperRendererError.cannotCreateBitmap
                }
                image = crop
            }
            let rect = CGRect(x: 0, y: height - 16 - 200 - index * 216, width: 720, height: 200)
            context.draw(image, in: rect)
            let name = item.name.components(separatedBy: .controlCharacters).joined(separator: " ")
            let nameLine = CTLineCreateWithAttributedString(NSAttributedString(string: String(name.prefix(160)), attributes: [
                .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 13, nil)
            ]))
            let nameWidth = min(220, max(40, ceil(CTLineGetTypographicBounds(nameLine, nil, nil, nil))))
            let fileX = 104 + nameWidth + 20
            // Treat the menu as one surface: a bright patch under the clock should
            // not independently invert it. This is a consistent export style,
            // not an attempt to reproduce macOS's private appearance decisions.
            let color = menuTextColor(image, region: CGRect(x: 0, y: 0, width: image.width, height: Int(24 * scale)))
            for (text, x, width) in [("WandelBar", 14.0, 76.0), (name, 104, nameWidth),
                                      ("File", fileX, 25), ("Edit", fileX + 41, 26),
                                      ("View", fileX + 83, 32), ("Mon 9:41", 639, 67)] {
                drawText(text, x: x, y: rect.maxY - 17, in: context,
                         size: 13, bold: text == "WandelBar" || x == 104, color: color, maxWidth: width)
            }
        }
        guard let image = context.makeImage() else { throw WallpaperRendererError.cannotCreateBitmap }
        return image
    }

    static func menuTextColor(_ image: CGImage, region: CGRect) -> CGColor {
        guard let crop = image.cropping(to: region),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return CGColor(gray: 1, alpha: 1) }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            guard let sample = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            sample.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let channels = pixel.prefix(3).map { value -> Double in
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        // Retain light text on mixed and moderately light wallpaper; reserve dark
        // text for a predominantly bright panel. A small shadow supports contrast.
        return CGColor(gray: luminance < 0.55 ? 1 : 0, alpha: 1)
    }

    private static func drawText(_ text: String, x: CGFloat, y: CGFloat, in context: CGContext,
                                 size: CGFloat, bold: Bool = false,
                                 color: CGColor = CGColor(gray: 0.15, alpha: 1), maxWidth: CGFloat = 912) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil),
            .foregroundColor: color
        ]
        let cleaned = text.components(separatedBy: .controlCharacters).joined(separator: " ")
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(cleaned.prefix(160)), attributes: attributes))
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let fitted = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) ?? line
        context.saveGState()
        context.clip(to: CGRect(x: x, y: y - 5, width: maxWidth, height: size + 12))
        if (color.components?.first ?? 0) > 0.9 {
            context.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1,
                              color: CGColor(gray: 0, alpha: 0.45))
        }
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(fitted, context)
        context.restoreGState()
    }
}
