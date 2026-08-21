import AppKit
import Testing
@testable import WandelBar

@Test func presetCatalogKeepsEveryPresetOnceAndAppendsUserPresets() {
    let userPreset = EffectPreset(
        id: "user.ocean",
        name: "Ocean",
        kind: .user,
        settings: .default
    )

    let sections = PresetCatalogSection.make(
        builtInSections: EffectPreset.builtInSections,
        userPresets: [userPreset]
    )

    let ids = sections.flatMap(\.presets).map(\.id)
    #expect(ids.count == Set(ids).count)
    #expect(Set(ids) == Set(EffectPreset.builtIns.map(\.id) + [userPreset.id]))
    #expect(sections.last?.title == "My Presets")
}

@MainActor
@Test func bundledPresetSampleBackgroundIsAvailableSynchronously() throws {
    let image = try #require(PresetSampleBackground.image)

    #expect(image.size.width / image.size.height > 2.5)
}

@Test func presetCatalogPreservesTheSectionTitlesFromThePresetCatalog() {
    let source = [
        EffectPresetSection(id: "basic", title: "Basic", presets: []),
        EffectPresetSection(id: "cupertino", title: "Cupertino", presets: []),
        EffectPresetSection(id: "redmond", title: "Redmond", presets: [])
    ]

    let sections = PresetCatalogSection.make(
        builtInSections: source,
        userPresets: []
    )

    #expect(sections.map(\.title) == ["Basic", "Cupertino", "Redmond", "My Presets"])
    #expect(sections.last?.presets.isEmpty == true)
}

@Test func twoColumnPresetCatalogFitsInsideThePopoverWidth() {
    let layout = PresetCatalogLayout(containerWidth: 360)

    #expect(layout.cardWidth == 159)
    #expect(layout.previewSize == CGSize(width: 159, height: 66))
    #expect(
        layout.horizontalPadding
            + layout.cardWidth
            + layout.columnSpacing
            + layout.cardWidth
            + layout.horizontalPadding
            == 360
    )
}

@Test func presetSelectorIsCenteredIndependentlyOfItsLabel() {
    let layout = PresetControlRowLayout(availableWidth: 328)

    #expect(layout.selectorFrame.width == 196)
    #expect(layout.selectorFrame.midX == 164)
}

@Test func presetPreviewContextKeyChangesWithWallpaperIdentity() {
    let display = DisplaySnapshot(
        id: "catalog-preview-key",
        localizedName: "Catalog Preview",
        frame: CGRect(x: 0, y: 0, width: 320, height: 200),
        backingScaleFactor: 1,
        statusBarThickness: 24
    )
    let desktop = StoredDesktop(
        urlString: "file:///tmp/wallpaper.png",
        imageScaling: nil,
        allowClipping: nil,
        fillColorData: nil,
        sourceIdentity: "file:first",
        generatedPath: nil
    )
    let first = PresetPreviewContext(
        sourceURL: URL(fileURLWithPath: "/tmp/wallpaper.png"),
        display: display,
        storedDesktop: desktop,
        sourceIdentity: "file:first"
    )
    let second = PresetPreviewContext(
        sourceURL: URL(fileURLWithPath: "/tmp/wallpaper.png"),
        display: display,
        storedDesktop: desktop,
        sourceIdentity: "file:second"
    )

    #expect(first.cacheKey != second.cacheKey)
}

@MainActor
@Test func presetPreviewRendererProducesAnExactTopStrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceURL = directory.appendingPathComponent("wallpaper.png")
    try solidImageData(width: 320, height: 200).write(to: sourceURL)
    let display = DisplaySnapshot(
        id: "catalog-preview",
        localizedName: "Catalog Preview",
        frame: CGRect(x: 0, y: 0, width: 320, height: 200),
        backingScaleFactor: 1,
        statusBarThickness: 24
    )

    let preview = try WallpaperRenderer().renderPreview(
        sourceURL: sourceURL,
        display: display,
        desktopOptions: DesktopRenderOptions(
            imageScaling: .scaleProportionallyUpOrDown,
            allowClipping: true,
            fillColor: .black
        ),
        settings: .default,
        size: CGSize(width: 180, height: 64)
    )

    #expect(preview.width == 180)
    #expect(preview.height == 64)
}

@MainActor
@Test func presetSamplePreviewRendererProducesAnExactTopStrip() throws {
    let preview = try WallpaperRenderer().renderSamplePreview(
        settings: .default,
        size: CGSize(width: 180, height: 64)
    )

    #expect(preview.width == 180)
    #expect(preview.height == 64)
}

@MainActor
private func solidImageData(width: Int, height: Int) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
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
    ))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.systemTeal.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
    NSGraphicsContext.restoreGraphicsState()

    return try #require(bitmap.representation(using: .png, properties: [:]))
}
