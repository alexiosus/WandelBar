import AppKit
import CoreImage

enum WallpaperRendererError: LocalizedError {
    case cannotLoadImage(URL)
    case cannotCreateBitmap
    case cannotRenderBlur
    case cannotEncodeImage

    var errorDescription: String? {
        switch self {
        case .cannotLoadImage(let url):
            return "cannot load \(url.lastPathComponent)"
        case .cannotCreateBitmap:
            return "cannot create bitmap"
        case .cannotRenderBlur:
            return "cannot render blur"
        case .cannotEncodeImage:
            return "cannot encode image"
        }
    }
}

struct WallpaperRenderer {
    private static let ciContext = CIContext(options: [
        .useSoftwareRenderer: false
    ])
    private static let baseImageCache = BaseImageCache()

    func render(
        sourceURL: URL,
        outputURL: URL,
        display: DisplaySnapshot,
        desktopOptions: DesktopRenderOptions,
        settings: WallpaperEffectSettings,
        textureURL: URL? = nil
    ) throws {
        let baseImage = try makeScreenSizedImage(
            sourceURL: sourceURL,
            display: display,
            desktopOptions: desktopOptions
        )

        let blurredImage = try applyTopEffect(
            to: baseImage,
            display: display,
            settings: settings,
            textureURL: textureURL
        )
        let bitmap = NSBitmapImageRep(cgImage: blurredImage)

        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.96]
        ) else {
            throw WallpaperRendererError.cannotEncodeImage
        }

        try data.write(to: outputURL, options: .atomic)
    }

    /// Renders a deliberately enlarged top-of-screen sample for preset cards. Using the
    /// real display aspect ratio keeps wallpaper placement representative, while keeping
    /// effect geometry in points makes the menu-bar treatment legible at thumbnail size.
    func renderPreview(
        sourceURL: URL,
        display: DisplaySnapshot,
        desktopOptions: DesktopRenderOptions,
        settings: WallpaperEffectSettings,
        textureURL: URL? = nil,
        size: CGSize
    ) throws -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let displaySize = display.pixelSize
        let fullHeight = max(
            height,
            Int((CGFloat(width) * displaySize.height / max(1, displaySize.width)).rounded())
        )
        let previewFrame = CGRect(x: 0, y: 0, width: width, height: fullHeight)
        let menuBarHeight = min(CGFloat(fullHeight), max(24, display.menuBarHeightPoints))
        let previewDisplay = DisplaySnapshot(
            id: "\(display.id)-preset-preview",
            localizedName: display.localizedName,
            frame: previewFrame,
            visibleFrame: previewFrame.insetBy(dx: 0, dy: menuBarHeight / 2)
                .offsetBy(dx: 0, dy: -menuBarHeight / 2),
            backingScaleFactor: 1,
            statusBarThickness: menuBarHeight
        )
        let baseImage = try makeScreenSizedImage(
            sourceURL: sourceURL,
            display: previewDisplay,
            desktopOptions: desktopOptions
        )
        let effected = try applyTopEffect(
            to: baseImage,
            display: previewDisplay,
            settings: settings,
            textureURL: textureURL
        )
        let cropRect = CGRect(
            x: 0,
            y: max(0, fullHeight - height),
            width: width,
            height: height
        )
        guard let preview = Self.ciContext.createCGImage(CIImage(cgImage: effected), from: cropRect) else {
            throw WallpaperRendererError.cannotRenderBlur
        }
        return preview
    }

    /// Renders the same preset treatment over a built-in neutral scene when the current
    /// wallpaper cannot be read. The scene deliberately contains cool, warm, light, and
    /// dark areas so blur, tint, saturation, and texture differences remain visible.
    func renderSamplePreview(
        settings: WallpaperEffectSettings,
        textureURL: URL? = nil,
        menuBarHeightPoints: CGFloat = 24,
        size: CGSize
    ) throws -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let fullHeight = height
        let frame = CGRect(x: 0, y: 0, width: width, height: fullHeight)
        let menuBarHeight = min(CGFloat(fullHeight), max(24, menuBarHeightPoints))
        let display = DisplaySnapshot(
            id: "preset-sample",
            localizedName: "Sample Background",
            frame: frame,
            visibleFrame: frame.insetBy(dx: 0, dy: menuBarHeight / 2)
                .offsetBy(dx: 0, dy: -menuBarHeight / 2),
            backingScaleFactor: 1,
            statusBarThickness: menuBarHeight
        )
        guard let sourceURL = PresetSampleBackground.url else {
            throw WallpaperRendererError.cannotCreateBitmap
        }
        let baseImage = try makeScreenSizedImage(
            sourceURL: sourceURL,
            display: display,
            desktopOptions: DesktopRenderOptions(
                imageScaling: .scaleProportionallyUpOrDown,
                allowClipping: true,
                fillColor: .black
            )
        )
        let effected = try applyTopEffect(
            to: baseImage,
            display: display,
            settings: settings,
            textureURL: textureURL
        )
        let cropRect = CGRect(
            x: 0,
            y: max(0, fullHeight - height),
            width: width,
            height: height
        )
        guard let preview = Self.ciContext.createCGImage(CIImage(cgImage: effected), from: cropRect) else {
            throw WallpaperRendererError.cannotRenderBlur
        }
        return preview
    }

    private func makeScreenSizedImage(
        sourceURL: URL,
        display: DisplaySnapshot,
        desktopOptions: DesktopRenderOptions
    ) throws -> CGImage {
        let cacheKey = baseImageCacheKey(
            sourceURL: sourceURL,
            display: display,
            desktopOptions: desktopOptions
        )
        if let cached = Self.baseImageCache.image(forKey: cacheKey) {
            return cached
        }

        guard let sourceImage = NSImage(contentsOf: sourceURL) else {
            throw WallpaperRendererError.cannotLoadImage(sourceURL)
        }

        let pixelSize = display.pixelSize
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw WallpaperRendererError.cannotCreateBitmap
        }

        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw WallpaperRendererError.cannotCreateBitmap
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        context.imageInterpolation = NSImageInterpolation.high

        let targetRect = CGRect(origin: .zero, size: pixelSize)
        let fillColor = desktopOptions.fillColor ?? .black
        fillColor.setFill()
        NSBezierPath(rect: targetRect).fill()

        let sourcePixelSize = sourceImage.bestPixelSize
        let destination = destinationRect(
            sourceSize: sourcePixelSize,
            targetSize: pixelSize,
            imageScaling: desktopOptions.imageScaling,
            allowClipping: desktopOptions.allowClipping
        )

        sourceImage.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = bitmap.cgImage else {
            throw WallpaperRendererError.cannotCreateBitmap
        }

        Self.baseImageCache.insert(
            cgImage,
            forKey: cacheKey,
            cost: width * height * 4
        )
        return cgImage
    }

    func applyTopEffect(
        to cgImage: CGImage,
        display: DisplaySnapshot,
        settings: WallpaperEffectSettings,
        textureURL: URL?
    ) throws -> CGImage {
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        let scale = display.backingScaleFactor
        let settings = settings.clamped
        let blurRadius = settings.blurRadiusPoints * scale
        let topInset = display.menuBarHeightPoints * scale
        // The band is a solid (fully-blurred) region stacked on a fade tail:
        //   Length = solid height, Fade = tail height, total = Length + Fade.
        // Length may be shorter than the menu bar (so the fade starts inside the bar), and
        // Fade extends the band downward past it. The whole band is floored at the menu bar
        // so the bar stays covered; if that floor kicks in, the solid region absorbs the
        // slack while the fade keeps its length.
        let fadeHeight = min(settings.fadeLengthPoints * scale, extent.height)
        let bandHeight = min(extent.height, max(topInset, settings.blurLengthPoints * scale + fadeHeight))
        let bandBottom = max(0, extent.maxY - bandHeight)

        let blurred = try blurredImage(input, extent: extent, radius: blurRadius)

        let saturated = applySaturation(
            to: blurred,
            extent: extent,
            saturation: settings.saturation
        )

        let adjustedBlur = applyTint(
            to: saturated,
            extent: extent,
            bandHeight: bandHeight,
            color: settings.tintColor,
            strength: settings.tintStrength,
            solid: settings.solidTint
        )

        let texturedBlur = applyTexture(
            to: adjustedBlur,
            textureURL: textureURL,
            extent: extent,
            bandBottom: bandBottom,
            bandHeight: bandHeight,
            mode: settings.textureBlendMode,
            strength: settings.textureStrength,
            layoutMode: settings.textureLayoutMode,
            verticalPosition: settings.textureVerticalPosition,
            isEnabled: settings.textureID != nil
        )

        guard let mask = CIFilter(
            name: "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: 0, y: bandBottom),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
                // Fade of 0 sets fadeHeight to 0; keep a 1px ramp so CILinearGradient
                // isn't degenerate (point0 == point1) — visually this still reads as sharp.
                "inputPoint1": CIVector(x: 0, y: min(extent.maxY, bandBottom + max(fadeHeight, 1))),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            ]
        )?.outputImage?.cropped(to: extent) else {
            throw WallpaperRendererError.cannotRenderBlur
        }

        let background = applyBandShadow(
            to: input,
            extent: extent,
            bandBottom: bandBottom,
            scale: scale,
            strength: settings.fadeLengthPoints == 0 ? settings.shadowStrength : 0,
            lengthPoints: settings.shadowLengthPoints
        )

        guard let composed = CIFilter(
            name: "CIBlendWithAlphaMask",
            parameters: [
                kCIInputImageKey: texturedBlur,
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask
            ]
        )?.outputImage?.cropped(to: extent) else {
            throw WallpaperRendererError.cannotRenderBlur
        }

        guard let output = Self.ciContext.createCGImage(composed, from: extent) else {
            throw WallpaperRendererError.cannotRenderBlur
        }

        return output
    }

    private func applyBandShadow(
        to input: CIImage,
        extent: CGRect,
        bandBottom: CGFloat,
        scale: CGFloat,
        strength: Double,
        lengthPoints: Double
    ) -> CIImage {
        let normalizedStrength = min(max(strength, 0), 1)
        let normalizedLength = min(max(lengthPoints, 0), 32)
        guard normalizedStrength > 0,
              normalizedLength > 0,
              bandBottom > extent.minY else { return input }

        let shadowReach = min(normalizedLength * scale, bandBottom - extent.minY)
        let shadowBottom = bandBottom - shadowReach
        guard shadowReach > 0,
              let ambientMask = CIFilter(
                name: "CISmoothLinearGradient",
                parameters: [
                    "inputPoint0": CIVector(x: 0, y: shadowBottom),
                    "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 1),
                    "inputPoint1": CIVector(x: 0, y: bandBottom),
                    "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
                ]
              )?.outputImage else {
            return input
        }

        let alphaMask = ambientMask
            .applyingFilter("CIMaskToAlpha")
            .cropped(to: extent)
        let shadowColor = CIImage(
            color: CIColor(
                red: 0,
                green: 0,
                blue: 0,
                alpha: normalizedStrength * 0.59
            )
        )
        let shadowedInput = shadowColor.composited(over: input)
        return CIFilter(
            name: "CIBlendWithAlphaMask",
            parameters: [
                kCIInputImageKey: shadowedInput,
                kCIInputBackgroundImageKey: input,
                kCIInputMaskImageKey: alphaMask
            ]
        )?.outputImage?.cropped(to: extent) ?? input
    }

    static func textureTransform(
        textureExtent: CGRect,
        renderExtent: CGRect,
        bandBottom: CGFloat,
        bandHeight: CGFloat,
        layoutMode: TextureLayoutMode = .fitWidth,
        verticalPosition: Double = 0
    ) -> CGAffineTransform {
        guard textureExtent.width > 0, textureExtent.height > 0 else {
            return .identity
        }

        let widthScale = renderExtent.width / textureExtent.width
        let heightScale = bandHeight / textureExtent.height
        let scaleX: CGFloat
        let scaleY: CGFloat
        switch layoutMode {
        case .fitWidth:
            scaleX = widthScale
            scaleY = widthScale
        case .fillBand:
            let scale = max(widthScale, heightScale)
            scaleX = scale
            scaleY = scale
        case .stretchToBand:
            scaleX = widthScale
            scaleY = heightScale
        }

        let scaledWidth = textureExtent.width * scaleX
        let scaledHeight = textureExtent.height * scaleY
        let normalizedPosition = CGFloat(min(max(verticalPosition, -1), 1))
        let alignment = (normalizedPosition + 1) / 2
        let targetX = renderExtent.midX - scaledWidth / 2
        let targetY = bandBottom + (bandHeight - scaledHeight) * alignment
        return CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: targetX - textureExtent.minX * scaleX,
            ty: targetY - textureExtent.minY * scaleY
        )
    }

    private func applyTexture(
        to image: CIImage,
        textureURL: URL?,
        extent: CGRect,
        bandBottom: CGFloat,
        bandHeight: CGFloat,
        mode: TextureBlendMode,
        strength: Double,
        layoutMode: TextureLayoutMode,
        verticalPosition: Double,
        isEnabled: Bool
    ) -> CIImage {
        let normalizedStrength = min(max(strength, 0), 1)
        guard isEnabled,
              normalizedStrength > 0,
              let textureURL,
              let sourceTexture = CIImage(contentsOf: textureURL) else {
            return image
        }

        let transform = Self.textureTransform(
            textureExtent: sourceTexture.extent,
            renderExtent: extent,
            bandBottom: bandBottom,
            bandHeight: bandHeight,
            layoutMode: layoutMode,
            verticalPosition: verticalPosition
        )
        let horizontallyExtendedTexture = sourceTexture
            .clampedToExtent()
            .cropped(to: sourceTexture.extent.insetBy(dx: -1, dy: 0))
        let placedTexture = horizontallyExtendedTexture
            .transformed(by: transform)
            .cropped(to: extent)
        let strengthenedTexture = placedTexture
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: normalizedStrength)
            ])
            .cropped(to: extent)

        let filterName: String
        switch mode {
        case .normal:
            filterName = "CISourceOverCompositing"
        case .screen:
            filterName = "CIScreenBlendMode"
        case .multiply:
            filterName = "CIMultiplyBlendMode"
        case .softLight:
            filterName = "CISoftLightBlendMode"
        case .overlay:
            filterName = "CIOverlayBlendMode"
        }

        return strengthenedTexture
            .applyingFilter(filterName, parameters: [
                kCIInputBackgroundImageKey: image
            ])
            .cropped(to: extent)
    }

    private func blurredImage(
        _ input: CIImage,
        extent: CGRect,
        radius: CGFloat
    ) throws -> CIImage {
        guard radius > 0 else {
            return input
        }

        return input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: radius
            ])
            .cropped(to: extent)
    }

    private func applySaturation(
        to image: CIImage,
        extent: CGRect,
        saturation: Double
    ) -> CIImage {
        let normalized = min(max(saturation, -1), 1)

        guard normalized != 0 else {
            return image
        }

        // Map -1...1 to CIColorControls saturation 0...2 (0 = grayscale, 1 = unchanged).
        return image
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + normalized
            ])
            .cropped(to: extent)
    }

    private func applyTint(
        to image: CIImage,
        extent: CGRect,
        bandHeight: CGFloat,
        color: TintColor,
        strength: Double,
        solid: Bool
    ) -> CIImage {
        let normalized = min(max(strength, 0), 1)

        guard normalized > 0 else {
            return image
        }

        // Solid: a uniform layer that reaches a fully opaque color at full strength.
        // Gradient wash: capped at 0.8 and fading to transparent at the band's lower
        // edge, so the wallpaper always shows through.
        // Both gradient stops use the SAME RGB and only vary alpha — otherwise
        // CILinearGradient interpolates the colors too, bleeding a different hue through
        // the middle of the band.
        let maxAlpha = solid ? 1.0 : 0.8
        let topAlpha = maxAlpha * normalized
        let bottomAlpha = solid ? topAlpha : 0
        let tint = color.clamped

        guard let overlay = CIFilter(
            name: "CILinearGradient",
            parameters: [
                "inputPoint0": CIVector(x: 0, y: max(0, extent.maxY - bandHeight)),
                "inputColor0": CIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: bottomAlpha),
                "inputPoint1": CIVector(x: 0, y: extent.maxY),
                "inputColor1": CIColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: topAlpha)
            ]
        )?.outputImage?.cropped(to: extent) else {
            return image
        }

        return overlay
            .applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputBackgroundImageKey: image
            ])
            .cropped(to: extent)
    }

    private func destinationRect(
        sourceSize: CGSize,
        targetSize: CGSize,
        imageScaling: NSImageScaling,
        allowClipping: Bool
    ) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CGRect(origin: .zero, size: targetSize)
        }

        if imageScaling == .scaleAxesIndependently {
            return CGRect(origin: .zero, size: targetSize)
        }

        let scaleX = targetSize.width / sourceSize.width
        let scaleY = targetSize.height / sourceSize.height
        let scale: CGFloat

        if allowClipping {
            scale = max(scaleX, scaleY)
        } else {
            switch imageScaling {
            case .scaleNone:
                scale = 1
            case .scaleProportionallyDown:
                scale = min(1, min(scaleX, scaleY))
            case .scaleProportionallyUpOrDown:
                scale = min(scaleX, scaleY)
            case .scaleAxesIndependently:
                scale = 1
            @unknown default:
                scale = min(scaleX, scaleY)
            }
        }

        let renderedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )

        return CGRect(
            x: (targetSize.width - renderedSize.width) / 2,
            y: (targetSize.height - renderedSize.height) / 2,
            width: renderedSize.width,
            height: renderedSize.height
        )
    }

    private func baseImageCacheKey(
        sourceURL: URL,
        display: DisplaySnapshot,
        desktopOptions: DesktopRenderOptions
    ) -> String {
        let fillColor = StoredDesktop.archiveColor(desktopOptions.fillColor)?
            .base64EncodedString() ?? "default-fill"

        return FileCacheKey.digest([
            FileCacheKey.sourceSignature(for: sourceURL, pixelSize: display.pixelSize),
            String(desktopOptions.imageScaling.rawValue),
            String(desktopOptions.allowClipping),
            fillColor
        ])
    }
}

private final class BaseImageCache: @unchecked Sendable {
    private final class Entry {
        let image: CGImage

        init(image: CGImage) {
            self.image = image
        }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: CGImage, forKey key: String, cost: Int) {
        cache.setObject(Entry(image: image), forKey: key as NSString, cost: cost)
    }
}

private extension NSImage {
    var bestPixelSize: CGSize {
        var largest = CGSize.zero

        for representation in representations {
            if representation.pixelsWide > Int(largest.width)
                || representation.pixelsHigh > Int(largest.height) {
                largest = CGSize(
                    width: representation.pixelsWide,
                    height: representation.pixelsHigh
                )
            }
        }

        if largest.width > 0, largest.height > 0 {
            return largest
        }

        return size
    }
}
