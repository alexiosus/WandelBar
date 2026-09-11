import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import WandelBar

@Test func sharingMarkdownEscapesUntrustedPresetNames() {
    let text = PresetSharingService.markdown(names: ["[Click](https://bad.example)\n# Fake"], previewNames: ["Preview-1.png"])
    #expect(!text.contains("\n# Fake"))
    #expect(text.contains("\\[Click\\]"))
    #expect(text.contains("standard sample background"))
    #expect(text.contains("Presets.zip"))
}

@Test func sharingRendersSampleWithoutWallpaperContext() throws {
    let image = try SharePreviewRenderer.render([
        SharePreviewItem(name: "Test", settings: .default, textureURL: nil)
    ])
    #expect(image.width == 2160)
    #expect(image.height > 100)
}

@Test func sharingPreviewLeavesRoomForWallpaperContext() throws {
    let image = try SharePreviewRenderer.render([SharePreviewItem(name: "Acrylic", settings: .default, textureURL: nil)])
    #expect(image.height == 696)
}

@Test func discussionBodyNeedsNoBrokenLocalImageLinksOrEditingInstructions() {
    let text = PresetSharingService.markdown(names: ["Acrylic"], previewNames: ["Preview-1.png"])
    #expect(!text.contains("](Preview-"))
    #expect(!text.contains("Replace the local"))
    #expect(!text.contains("Attach Presets.zip"))
}

@Test func discussionDraftPreservesTextAndOfficialDestination() throws {
    let title = "Glass + blue & 日本 #1"
    let body = "## Presets\n\nA+B & [sample]\n100%"
    let url = try #require(DiscussionDraft.url(title: title, body: body))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "github.com")
    #expect(components.path == "/alexiosus/WandelBar/discussions/new")
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query["title"] == title)
    #expect(query["body"] == body)
    #expect(query["category"] == "preset-exchange")
    #expect(!url.absoluteString.contains("+"))
    #expect(DiscussionDraft.url(title: title, body: String(repeating: "🌊", count: 1000)) == nil)
}

@Test func sharingMenuTextContrastsWithLightAndDarkBars() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 100, height: 24, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for gray: CGFloat in [0, 1] {
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 24))
        let image = try #require(context.makeImage())
        let color = SharePreviewRenderer.menuTextColor(image, region: CGRect(x: 0, y: 0, width: 100, height: 24))
        #expect(color.components?.first == 1 - gray)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["WANDELBAR_QA_OUTPUT"] != nil))
func renderDiscussionPreviewArtifacts() throws {
    let path = try #require(ProcessInfo.processInfo.environment["WANDELBAR_QA_OUTPUT"])
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var dark = WallpaperEffectSettings.default
    dark.solidTint = true
    dark.tintStrength = 1
    dark.tintColor = .black
    var light = dark
    light.tintColor = TintColor(red: 1, green: 1, blue: 1)
    for (name, items) in [
        ("discussion-preview", [SharePreviewItem(name: "Acrylic", settings: .default, textureURL: nil)]),
        ("discussion-contrast", [SharePreviewItem(name: "Dark", settings: dark, textureURL: nil),
                                  SharePreviewItem(name: String(repeating: "Long preset name ", count: 15), settings: light, textureURL: nil)])
    ] {
        let image = try SharePreviewRenderer.render(items)
        let url = directory.appendingPathComponent(name + ".png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

@Test func sharingRejectsArchivesTooLargeForGitHub() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-limit-" + UUID().uuidString + ".zip")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.truncate(atOffset: 25_000_001)
    #expect(throws: PresetSharingError.self) {
        try PresetSharingService.validateAttachment(url, limitMB: 25)
    }
}

@Test func sharingSeparatorsAreTransparentAndNamesAppearInImage() throws {
    let first = SharePreviewItem(name: "Acrylic", settings: .default, textureURL: nil)
    let second = SharePreviewItem(name: "Frosted", settings: .default, textureURL: nil)
    let a = try SharePreviewRenderer.render([first])
    let b = try SharePreviewRenderer.render([second])
    let aData = try #require(a.dataProvider?.data)
    let bData = try #require(b.dataProvider?.data)
    #expect((aData as Data) != (bData as Data))
    let combined = try SharePreviewRenderer.render([first, second])
    for y in [0, combined.height / 2, combined.height - 1] {
        let gap = try #require(combined.cropping(to: CGRect(x: 10, y: y, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 255, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(gap, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(pixel[3] == 0)
    }
}

@Test func sharedWallpaperMenuGeometryDoesNotDependOnPhysicalMenuBarHeight() throws {
    let source = try #require(PresetSampleBackground.renderURL)
    var settings = WallpaperEffectSettings.default
    settings.blurLengthPoints = 0
    settings.fadeLengthPoints = 0
    settings.solidTint = true
    settings.tintStrength = 1
    settings.tintColor = .black
    let item = SharePreviewItem(name: "Geometry", settings: settings, textureURL: nil)
    func render(menuHeight: CGFloat) throws -> CGImage {
        let display = DisplaySnapshot(id: "test", localizedName: "Test", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScaleFactor: 2, statusBarThickness: menuHeight)
        let context = PresetPreviewContext(sourceURL: source, display: display,
            storedDesktop: StoredDesktop(urlString: source.absoluteString, imageScaling: nil, allowClipping: true, fillColorData: nil),
            sourceIdentity: "test")
        return try SharePreviewRenderer.render([item], wallpaper: context)
    }
    let standard = try render(menuHeight: 24)
    let tall = try render(menuHeight: 38)
    #expect(standard.width == tall.width && standard.height == tall.height)
    let a = try #require(standard.dataProvider?.data)
    let b = try #require(tall.dataProvider?.data)
    let geometryMatches = (a as Data) == (b as Data)
    #expect(geometryMatches)
}

@Test func sharingMenuKeepsWhiteTextOnModeratelyLightBackground() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 100, height: 24,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 0.65, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 24))
    let image = try #require(context.makeImage())
    let color = SharePreviewRenderer.menuTextColor(image, region: CGRect(x: 0, y: 0, width: 100, height: 24))
    #expect(color.components?.first == 1)
}
