import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WandelBar

@MainActor
@Test func rendererProducesAScreenSizedWallpaper() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.png")
    let outputURL = directory.appendingPathComponent("output.jpg")
    try makeSourceImageData(width: 48, height: 32).write(to: sourceURL)

    let display = DisplaySnapshot(
        id: "test-display",
        localizedName: "Test Display",
        frame: CGRect(x: 0, y: 0, width: 64, height: 40),
        backingScaleFactor: 1,
        statusBarThickness: 12
    )

    try WallpaperRenderer().render(
        sourceURL: sourceURL,
        outputURL: outputURL,
        display: display,
        desktopOptions: DesktopRenderOptions(
            imageScaling: .scaleProportionallyUpOrDown,
            allowClipping: true,
            fillColor: .black
        ),
        settings: .default
    )

    let result = try #require(NSImage(contentsOf: outputURL))
    let pixelSize = result.bestTestPixelSize
    #expect(pixelSize.width == 64)
    #expect(pixelSize.height == 40)
    let imageSource = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    #expect(CGImageSourceGetType(imageSource) as String? == UTType.jpeg.identifier)
}

@MainActor
@Test func rendererPreservesSmallTextureAtHorizontalEdgesWhenSaved() throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("source.png")
    let textureURL = directory.appendingPathComponent("texture.png")
    let outputURL = directory.appendingPathComponent("output.jpg")
    try makeSourceImageData(width: 48, height: 32).write(to: sourceURL)
    try writeTextureFixtureImage(
        to: textureURL,
        type: .png,
        width: 352,
        height: 29
    )
    let display = DisplaySnapshot(
        id: "textured-test-display",
        localizedName: "Textured Test Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 50),
        backingScaleFactor: 2,
        statusBarThickness: 24
    )
    let settings = WallpaperEffectSettings(
        blurRadiusPoints: 30,
        blurLengthPoints: 24,
        fadeLengthPoints: 0,
        tintStrength: 0,
        tintColor: .black,
        solidTint: true,
        saturation: 0,
        textureID: "custom.fixture",
        textureBlendMode: .normal,
        textureStrength: 1,
        textureLayoutMode: .stretchToBand
    )

    try WallpaperRenderer().render(
        sourceURL: sourceURL,
        outputURL: outputURL,
        display: display,
        desktopOptions: DesktopRenderOptions(
            imageScaling: .scaleProportionallyUpOrDown,
            allowClipping: true,
            fillColor: .black
        ),
        settings: settings,
        textureURL: textureURL
    )

    let imageSource = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
    #expect(CGImageSourceGetType(imageSource) as String? == UTType.jpeg.identifier)
    let row = try rgbaRow(at: outputURL, y: 98, width: 3024)
    for channel in 0..<3 {
        #expect(abs(Int(row[0][channel]) - Int(row[8][channel])) <= 1)
        #expect(abs(Int(row[3023][channel]) - Int(row[3015][channel])) <= 1)
    }
}

@MainActor
private func makeSourceImageData(width: Int, height: Int) throws -> Data {
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
        throw RendererTestError.cannotCreateSource
    }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw RendererTestError.cannotCreateSource
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
    ) else {
        throw RendererTestError.cannotEncodeSource
    }
    return data
}

private func rgbaRow(at url: URL, y: Int, width: Int) throws -> [[UInt8]] {
    let image = try #require(CIImage(contentsOf: url))
    var bytes = [UInt8](repeating: 0, count: width * 4)
    CIContext(options: [.useSoftwareRenderer: true]).render(
        image,
        toBitmap: &bytes,
        rowBytes: width * 4,
        bounds: CGRect(x: 0, y: y, width: width, height: 1),
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
    )
    return stride(from: 0, to: bytes.count, by: 4).map {
        Array(bytes[$0..<($0 + 4)])
    }
}

@Test func textureTransformFitsWidthAndCentersOnBand() {
    let texture = CGRect(x: 0, y: 0, width: 800, height: 600)
    let render = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let transform = WallpaperRenderer.textureTransform(
        textureExtent: texture,
        renderExtent: render,
        bandBottom: 900,
        bandHeight: 100
    )
    let placed = texture.applying(transform)

    #expect(abs(placed.width - 1600) < 0.001)
    #expect(abs(placed.height - 1200) < 0.001)
    #expect(abs(placed.minX - render.minX) < 0.001)
    #expect(abs(placed.midY - 950) < 0.001)
}

@Test func textureLayoutModesHandleAHighNotchedMenuBar() {
    let texture = CGRect(x: 0, y: 0, width: 2048, height: 32)
    let render = CGRect(x: 0, y: 0, width: 3024, height: 200)

    let fitWidth = texture.applying(WallpaperRenderer.textureTransform(
        textureExtent: texture,
        renderExtent: render,
        bandBottom: 100,
        bandHeight: 78,
        layoutMode: .fitWidth,
        verticalPosition: 0
    ))
    let fillBand = texture.applying(WallpaperRenderer.textureTransform(
        textureExtent: texture,
        renderExtent: render,
        bandBottom: 100,
        bandHeight: 78,
        layoutMode: .fillBand,
        verticalPosition: 0
    ))
    let stretched = texture.applying(WallpaperRenderer.textureTransform(
        textureExtent: texture,
        renderExtent: render,
        bandBottom: 100,
        bandHeight: 78,
        layoutMode: .stretchToBand,
        verticalPosition: 0
    ))

    #expect(abs(fitWidth.width - 3024) < 0.001)
    #expect(abs(fitWidth.height - 47.25) < 0.001)
    #expect(abs(fillBand.height - 78) < 0.001)
    #expect(fillBand.width > 3024)
    #expect(abs(stretched.width - 3024) < 0.001)
    #expect(abs(stretched.height - 78) < 0.001)
}

@Test func textureVerticalPositionAlignsCroppedContent() {
    let texture = CGRect(x: 0, y: 0, width: 800, height: 600)
    let render = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    let bottom = texture.applying(WallpaperRenderer.textureTransform(
        textureExtent: texture,
        renderExtent: render,
        bandBottom: 900,
        bandHeight: 100,
        layoutMode: .fitWidth,
        verticalPosition: -1
    ))
    let top = texture.applying(WallpaperRenderer.textureTransform(
        textureExtent: texture,
        renderExtent: render,
        bandBottom: 900,
        bandHeight: 100,
        layoutMode: .fitWidth,
        verticalPosition: 1
    ))

    #expect(abs(bottom.minY - 900) < 0.001)
    #expect(abs(top.maxY - 1000) < 0.001)
}

@Test @MainActor func zeroTextureStrengthIsPixelIdenticalToNoTexture() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    var settings = fixture.sharpBandSettings
    settings.textureID = "custom.fixture"
    settings.textureStrength = 0

    let none = try fixture.renderEffect(settings: fixture.sharpBandSettings, textureURL: nil)
    let zero = try fixture.renderEffect(settings: settings, textureURL: fixture.textureURL)
    #expect(fixture.rgbaBytes(none) == fixture.rgbaBytes(zero))
}

@Test @MainActor func textureChangesOnlyTheMaskedBand() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    var settings = fixture.sharpBandSettings
    settings.textureID = "custom.fixture"
    settings.textureStrength = 1
    settings.textureBlendMode = .screen

    let output = try fixture.renderEffect(settings: settings, textureURL: fixture.textureURL)
    #expect(fixture.pixel(output, x: 16, y: 1) != fixture.basePixel)
    #expect(fixture.pixel(output, x: 16, y: 31) == fixture.basePixel)
}

@Test @MainActor func shadowStrengthControlsDarknessBelowCrispBandEdge() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    var weakSettings = fixture.sharpBandSettings
    weakSettings.shadowStrength = 0.20
    weakSettings.shadowLengthPoints = 3
    let weak = try fixture.renderEffect(settings: weakSettings, textureURL: nil)
    var strongSettings = weakSettings
    strongSettings.shadowStrength = 0.80

    let strong = try fixture.renderEffect(settings: strongSettings, textureURL: nil)
    let weakEdge = fixture.pixel(weak, x: 16, y: 25)
    let strongEdge = fixture.pixel(strong, x: 16, y: 25)

    #expect(strongEdge[0] < weakEdge[0])
    #expect(strongEdge[1] < weakEdge[1])
    #expect(strongEdge[2] < weakEdge[2])
    #expect(fixture.pixel(strong, x: 16, y: 31) == fixture.basePixel)
}

@Test @MainActor func shadowFallsAwayMonotonicallyFromBandEdge() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    var settings = fixture.sharpBandSettings
    settings.shadowStrength = 1
    settings.shadowLengthPoints = 14

    let output = try fixture.renderEffect(settings: settings, textureURL: nil)
    for y in 24..<38 {
        let current = fixture.pixel(output, x: 16, y: y)
        let next = fixture.pixel(output, x: 16, y: y + 1)
        for channel in 0..<3 {
            #expect(Int(current[channel]) <= Int(next[channel]) + 2)
        }
    }
}

@Test @MainActor func maximumAmbientShadowBalancesEdgeContrast() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    var settings = fixture.sharpBandSettings
    settings.shadowStrength = 1
    settings.shadowLengthPoints = 14

    let output = try fixture.renderEffect(settings: settings, textureURL: nil)
    let firstShadowRow = fixture.pixel(output, x: 16, y: 24)
    let luminance = 0.2126 * Double(firstShadowRow[0])
        + 0.7152 * Double(firstShadowRow[1])
        + 0.0722 * Double(firstShadowRow[2])

    #expect(luminance >= 62)
    #expect(luminance <= 68)
}

@Test @MainActor func ambientShadowDistributesContrastThroughItsTail() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    var settings = fixture.sharpBandSettings
    settings.shadowStrength = 1
    settings.shadowLengthPoints = 14

    let output = try fixture.renderEffect(settings: settings, textureURL: nil)
    let edge = fixture.pixel(output, x: 16, y: 24)
    let midpoint = fixture.pixel(output, x: 16, y: 31)
    let base = fixture.basePixel
    let edgeLuminance = 0.2126 * Double(edge[0])
        + 0.7152 * Double(edge[1])
        + 0.0722 * Double(edge[2])
    let midpointLuminance = 0.2126 * Double(midpoint[0])
        + 0.7152 * Double(midpoint[1])
        + 0.0722 * Double(midpoint[2])
    let baseLuminance = 0.2126 * Double(base[0])
        + 0.7152 * Double(base[1])
        + 0.0722 * Double(base[2])

    #expect(baseLuminance - midpointLuminance >= (baseLuminance - edgeLuminance) / 3)
}

@Test @MainActor func shadowReachesZeroSmoothlyAtConfiguredLength() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    var settings = fixture.sharpBandSettings
    settings.shadowStrength = 1
    settings.shadowLengthPoints = 14

    let output = try fixture.renderEffect(settings: settings, textureURL: nil)
    let lastShadowRow = fixture.pixel(output, x: 16, y: 37)
    let firstUnshadowedRow = fixture.pixel(output, x: 16, y: 38)

    #expect(abs(Int(lastShadowRow[0]) - Int(firstUnshadowedRow[0])) <= 3)
    #expect(abs(Int(lastShadowRow[1]) - Int(firstUnshadowedRow[1])) <= 3)
    #expect(abs(Int(lastShadowRow[2]) - Int(firstUnshadowedRow[2])) <= 3)
    #expect(abs(Int(firstUnshadowedRow[0]) - Int(fixture.basePixel[0])) <= 1)
    #expect(abs(Int(firstUnshadowedRow[1]) - Int(fixture.basePixel[1])) <= 1)
    #expect(abs(Int(firstUnshadowedRow[2]) - Int(fixture.basePixel[2])) <= 1)
}

@Test @MainActor func shadowLengthControlsHowFarItReachesBelowTheBand() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    var shortSettings = fixture.sharpBandSettings
    shortSettings.shadowStrength = 0.80
    shortSettings.shadowLengthPoints = 2
    let short = try fixture.renderEffect(settings: shortSettings, textureURL: nil)
    var longSettings = shortSettings
    longSettings.shadowLengthPoints = 8

    let long = try fixture.renderEffect(settings: longSettings, textureURL: nil)
    let shortPixel = fixture.pixel(short, x: 16, y: 28)
    let longPixel = fixture.pixel(long, x: 16, y: 28)

    #expect(longPixel[0] < shortPixel[0])
    #expect(longPixel[1] < shortPixel[1])
    #expect(longPixel[2] < shortPixel[2])
}

@Test @MainActor func shadowIsInactiveWhileFadeIsVisible() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    var baselineSettings = fixture.sharpBandSettings
    baselineSettings.fadeLengthPoints = 4
    let baseline = try fixture.renderEffect(settings: baselineSettings, textureURL: nil)
    var shadowSettings = baselineSettings
    shadowSettings.shadowStrength = 0.80
    shadowSettings.shadowLengthPoints = 8

    let output = try fixture.renderEffect(settings: shadowSettings, textureURL: nil)

    #expect(fixture.rgbaBytes(output) == fixture.rgbaBytes(baseline))
}

@Test @MainActor func unreadableTextureFallsBackToNoTexture() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    try Data("broken".utf8).write(to: fixture.textureURL)
    var settings = fixture.sharpBandSettings
    settings.textureID = "custom.fixture"
    settings.textureStrength = 1

    let none = try fixture.renderEffect(settings: fixture.sharpBandSettings, textureURL: nil)
    let missing = try fixture.renderEffect(settings: settings, textureURL: fixture.textureURL)
    #expect(fixture.rgbaBytes(none) == fixture.rgbaBytes(missing))
}

@Test @MainActor func allBlendModesProduceDistinctBandPixels() throws {
    let fixture = try RendererTextureFixture()
    defer { fixture.cleanUp() }
    var pixels = Set<[UInt8]>()

    for mode in TextureBlendMode.allCases {
        var settings = fixture.sharpBandSettings
        settings.textureID = "custom.fixture"
        settings.textureStrength = 1
        settings.textureBlendMode = mode
        let output = try fixture.renderEffect(settings: settings, textureURL: fixture.textureURL)
        pixels.insert(fixture.pixel(output, x: 16, y: 1))
    }

    #expect(pixels.count == 5)
}

@Test @MainActor func silverClassicMenuBarPresetSuppressesWallpaperColor() throws {
    let baseImage = try makeSolidCGImage(
        width: 2048,
        height: 128,
        red: 32,
        green: 118,
        blue: 220
    )
    let display = DisplaySnapshot(
        id: "classic-menu-bar-display",
        localizedName: "Classic Menu Bar Display",
        frame: CGRect(x: 0, y: 0, width: 1024, height: 64),
        backingScaleFactor: 2,
        statusBarThickness: 24
    )
    let presetsByID = Dictionary(
        uniqueKeysWithValues: EffectPreset.builtIns.map { ($0.id, $0) }
    )

    for presetID in [EffectPreset.BuiltInID.silverGlass] {
        let preset = try #require(presetsByID[presetID])
        let textureID = try #require(preset.settings.textureID)
        let textureAsset = try #require(TextureAsset.builtIns.first { $0.id == textureID })
        let texture = try #require(TextureAssetStore.bundledURL(for: textureAsset))
        let output = try WallpaperRenderer().applyTopEffect(
            to: baseImage,
            display: display,
            settings: preset.settings,
            textureURL: texture
        )

        #expect(meanChroma(inTopRowsOf: output, rowCount: 48) < 32)
    }
}

@Test @MainActor func blueClassicMenuBarPresetsRetainWallpaperColor() throws {
    let baseImage = try makeSolidCGImage(
        width: 2048,
        height: 128,
        red: 32,
        green: 118,
        blue: 220
    )
    let display = DisplaySnapshot(
        id: "blue-classic-menu-bar-display",
        localizedName: "Blue Classic Menu Bar Display",
        frame: CGRect(x: 0, y: 0, width: 1024, height: 64),
        backingScaleFactor: 2,
        statusBarThickness: 24
    )
    let presets = EffectPreset.builtIns.filter { $0.id == "built-in.coastal-glass" }
    #expect(presets.count == 1)

    for preset in presets {
        let output = try renderClassicPreset(preset, baseImage: baseImage, display: display)
        #expect(meanChroma(inTopRowsOf: output, rowCount: 48) > 55)
    }
}

@Test @MainActor func coastalLightIsBrighterAndMoreNeutralThanTranslucent() throws {
    let baseImage = try makeSolidCGImage(
        width: 2048,
        height: 128,
        red: 32,
        green: 118,
        blue: 220
    )
    let display = DisplaySnapshot(
        id: "coastal-variants-display",
        localizedName: "Coastal Variants Display",
        frame: CGRect(x: 0, y: 0, width: 1024, height: 64),
        backingScaleFactor: 2,
        statusBarThickness: 24
    )
    let presets = Dictionary(uniqueKeysWithValues: EffectPreset.builtIns.map { ($0.id, $0) })
    let light = try renderClassicPreset(
        try #require(presets["built-in.coastal-light"]),
        baseImage: baseImage,
        display: display
    )
    let translucent = try renderClassicPreset(
        try #require(presets["built-in.coastal-glass"]),
        baseImage: baseImage,
        display: display
    )

    #expect(meanLuminance(inTopRowsOf: light, rowCount: 48)
        - meanLuminance(inTopRowsOf: translucent, rowCount: 48) > 30)
    #expect(meanChroma(inTopRowsOf: translucent, rowCount: 48)
        - meanChroma(inTopRowsOf: light, rowCount: 48) > 20)
    #expect(verticalLuminanceRange(inTopRowsOf: light, rowCount: 48) > 55)
}

@Test @MainActor func coastalLightLetsWallpaperColorShowThroughTheBlurredMaterial() throws {
    let display = DisplaySnapshot(
        id: "coastal-light-transparency-display",
        localizedName: "Coastal Light Transparency Display",
        frame: CGRect(x: 0, y: 0, width: 1024, height: 64),
        backingScaleFactor: 2,
        statusBarThickness: 24
    )
    let preset = try #require(EffectPreset.builtIns.first {
        $0.id == EffectPreset.BuiltInID.coastalLight
    })
    let blue = try renderClassicPreset(
        preset,
        baseImage: try makeSolidCGImage(width: 2048, height: 128, red: 32, green: 118, blue: 220),
        display: display
    )
    let orange = try renderClassicPreset(
        preset,
        baseImage: try makeSolidCGImage(width: 2048, height: 128, red: 220, green: 100, blue: 32),
        display: display
    )

    let blueMean = meanRGB(inTopRowsOf: blue, rowCount: 48)
    let orangeMean = meanRGB(inTopRowsOf: orange, rowCount: 48)
    let wallpaperInfluence = zip(blueMean, orangeMean)
        .map { abs($0 - $1) }
        .reduce(0, +) / 3

    #expect(wallpaperInfluence > 55)
}


@Test @MainActor func stripedLightUsesAStableLightBackgroundInsteadOfWallpaperColor() throws {
    let display = DisplaySnapshot(
        id: "striped-light-display",
        localizedName: "Striped Light Display",
        frame: CGRect(x: 0, y: 0, width: 1024, height: 64),
        backingScaleFactor: 2,
        statusBarThickness: 24
    )
    let preset = try #require(EffectPreset.builtIns.first { $0.id == "built-in.striped-light" })
    let blue = try renderClassicPreset(
        preset,
        baseImage: try makeSolidCGImage(width: 2048, height: 128, red: 32, green: 118, blue: 220),
        display: display
    )
    let orange = try renderClassicPreset(
        preset,
        baseImage: try makeSolidCGImage(width: 2048, height: 128, red: 220, green: 100, blue: 32),
        display: display
    )

    let blueMean = meanRGB(inTopRowsOf: blue, rowCount: 48)
    let orangeMean = meanRGB(inTopRowsOf: orange, rowCount: 48)
    #expect(meanLuminance(inTopRowsOf: blue, rowCount: 48) > 150)
    #expect((try #require(blueMean.max())) - (try #require(blueMean.min())) < 12)
    #expect(zip(blueMean, orangeMean).map { abs($0 - $1) }.reduce(0, +) / 3 < 18)
}

@Test @MainActor func stripedLightRendersAPronouncedGlossRelief() throws {
    let display = DisplaySnapshot(
        id: "striped-relief-display",
        localizedName: "Striped Relief Display",
        frame: CGRect(x: 0, y: 0, width: 1024, height: 64),
        backingScaleFactor: 2,
        statusBarThickness: 24
    )
    let preset = try #require(EffectPreset.builtIns.first { $0.id == "built-in.striped-light" })
    let output = try renderClassicPreset(
        preset,
        baseImage: try makeSolidCGImage(width: 2048, height: 128, red: 120, green: 120, blue: 120),
        display: display
    )

    #expect(verticalLuminanceRange(inTopRowsOf: output, rowCount: 48) > 110)
}

@Test @MainActor func darkClassicPresetsRenderSubstantiallyDarkerThanLightVariants() throws {
    let baseImage = try makeSolidCGImage(
        width: 2048,
        height: 128,
        red: 190,
        green: 130,
        blue: 60
    )
    let display = DisplaySnapshot(
        id: "classic-variant-display",
        localizedName: "Classic Variant Display",
        frame: CGRect(x: 0, y: 0, width: 1024, height: 64),
        backingScaleFactor: 2,
        statusBarThickness: 24
    )
    let pairs = [
        (EffectPreset.BuiltInID.silverGlass, EffectPreset.BuiltInID.graphiteGlass),
        (EffectPreset.BuiltInID.coastalLight, EffectPreset.BuiltInID.coastalDark),
        ("built-in.striped-light", "built-in.striped-dark")
    ]
    let presets = Dictionary(uniqueKeysWithValues: EffectPreset.builtIns.map { ($0.id, $0) })

    for (lightID, darkID) in pairs {
        let light = try renderClassicPreset(
            try #require(presets[lightID]),
            baseImage: baseImage,
            display: display
        )
        let dark = try renderClassicPreset(
            try #require(presets[darkID]),
            baseImage: baseImage,
            display: display
        )
        #expect(meanLuminance(inTopRowsOf: light, rowCount: 48)
            - meanLuminance(inTopRowsOf: dark, rowCount: 48) > 70)
    }
}

@MainActor
private final class RendererTextureFixture {
    let files: TextureStoreFixture
    let textureURL: URL
    let baseImage: CGImage
    let display = DisplaySnapshot(
        id: "texture-display",
        localizedName: "Texture Display",
        frame: CGRect(x: 0, y: 0, width: 32, height: 64),
        backingScaleFactor: 1,
        statusBarThickness: 4
    )

    var sharpBandSettings: WallpaperEffectSettings {
        WallpaperEffectSettings(
            blurRadiusPoints: 0,
            blurLengthPoints: 24,
            fadeLengthPoints: 0,
            tintStrength: 0,
            tintColor: .black,
            solidTint: false,
            saturation: 0
        )
    }

    var basePixel: [UInt8] { pixel(baseImage, x: 16, y: 31) }

    init() throws {
        files = try TextureStoreFixture()
        textureURL = try files.makeImage(
            name: "renderer-texture",
            type: .png,
            width: 32,
            height: 32
        )
        baseImage = try makeSolidCGImage(
            width: 32,
            height: 64,
            red: 64,
            green: 100,
            blue: 160
        )
    }

    func renderEffect(
        settings: WallpaperEffectSettings,
        textureURL: URL?
    ) throws -> CGImage {
        try WallpaperRenderer().applyTopEffect(
            to: baseImage,
            display: display,
            settings: settings,
            textureURL: textureURL
        )
    }

    func rgbaBytes(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let bytes = rgbaBytes(image)
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    func cleanUp() {
        files.cleanUp()
    }

}

private func makeSolidCGImage(
    width: Int,
    height: Int,
    red: UInt8,
    green: UInt8,
    blue: UInt8
) throws -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw RendererTestError.cannotCreateSource
    }
    let color = CGColor(
        colorSpace: colorSpace,
        components: [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, 1]
    )!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw RendererTestError.cannotCreateSource
    }
    return image
}

private func meanChroma(inTopRowsOf image: CGImage, rowCount: Int) -> Double {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(
            data: storage.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var total = 0
    var count = 0
    for y in stride(from: 0, to: min(rowCount, height), by: 2) {
        for x in stride(from: 0, to: width, by: 16) {
            let offset = (y * width + x) * 4
            let channels = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
            total += (channels.max() ?? 0) - (channels.min() ?? 0)
            count += 1
        }
    }
    return count == 0 ? 0 : Double(total) / Double(count)
}

private func renderClassicPreset(
    _ preset: EffectPreset,
    baseImage: CGImage,
    display: DisplaySnapshot
) throws -> CGImage {
    let textureID = try #require(preset.settings.textureID)
    let asset = try #require(TextureAsset.builtIns.first { $0.id == textureID })
    let textureURL = try #require(TextureAssetStore.bundledURL(for: asset))
    return try WallpaperRenderer().applyTopEffect(
        to: baseImage,
        display: display,
        settings: preset.settings,
        textureURL: textureURL
    )
}

private func meanLuminance(inTopRowsOf image: CGImage, rowCount: Int) -> Double {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(
            data: storage.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var total = 0.0
    var count = 0
    for y in stride(from: 0, to: min(rowCount, height), by: 2) {
        for x in stride(from: 0, to: width, by: 16) {
            let offset = (y * width + x) * 4
            total += 0.2126 * Double(bytes[offset])
                + 0.7152 * Double(bytes[offset + 1])
                + 0.0722 * Double(bytes[offset + 2])
            count += 1
        }
    }
    return count == 0 ? 0 : total / Double(count)
}

private func meanRGB(inTopRowsOf image: CGImage, rowCount: Int) -> [Double] {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(
            data: storage.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var totals = [0.0, 0.0, 0.0]
    var count = 0
    for y in stride(from: 0, to: min(rowCount, height), by: 2) {
        for x in stride(from: 0, to: width, by: 16) {
            let offset = (y * width + x) * 4
            for channel in 0..<3 { totals[channel] += Double(bytes[offset + channel]) }
            count += 1
        }
    }
    return totals.map { count == 0 ? 0 : $0 / Double(count) }
}

private func verticalLuminanceRange(inTopRowsOf image: CGImage, rowCount: Int) -> Double {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(
            data: storage.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    let rowMeans = (0..<min(rowCount, height)).map { y in
        var total = 0.0
        var count = 0
        for x in stride(from: 0, to: width, by: 16) {
            let offset = (y * width + x) * 4
            total += 0.2126 * Double(bytes[offset])
                + 0.7152 * Double(bytes[offset + 1])
                + 0.0722 * Double(bytes[offset + 2])
            count += 1
        }
        return count == 0 ? 0 : total / Double(count)
    }
    return (rowMeans.max() ?? 0) - (rowMeans.min() ?? 0)
}

private enum RendererTestError: Error {
    case cannotCreateSource
    case cannotEncodeSource
}

private extension NSImage {
    var bestTestPixelSize: CGSize {
        representations.reduce(.zero) { current, representation in
            let candidate = CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
            return candidate.width * candidate.height > current.width * current.height
                ? candidate
                : current
        }
    }
}
