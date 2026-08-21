import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WandelBar

@Test func builtInTextureCatalogHasStableIdentityAndOrder() {
    #expect(TextureAsset.builtIns.map(\.id) == [
        "built-in.azure-reflection",
        "built-in.ocean-blue",
        "built-in.classic-blue",
        "built-in.classic-olive",
        "built-in.embedded-slate",
        "built-in.royal-noir",
        "built-in.striped-light",
        "built-in.striped-dark",
        "built-in.silver-glass",
        "built-in.graphite-glass",
        "built-in.coastal-light",
        "built-in.coastal-dark"
    ])
    #expect(TextureAsset.builtIns.map(\.name) == [
        "Azure Reflection",
        "Ocean Blue",
        "Classic Blue",
        "Classic Olive",
        "Embedded Slate",
        "Royal Noir",
        "Striped Light",
        "Striped Dark",
        "Silver Glass",
        "Graphite Glass",
        "Coastal Light",
        "Coastal Dark"
    ])
    #expect(TextureAsset.builtIns.allSatisfy { $0.kind == .builtIn })
}

@Test func redmondTextureResourcesMatchApprovedDimensions() throws {
    let expected: [(String, String, Int, Int)] = [
        ("built-in.azure-reflection", "AzureReflection.png", 802, 40),
        ("built-in.embedded-slate", "EmbeddedSlate.png", 592, 43),
        ("built-in.classic-blue", "ClassicBlue.png", 158, 28),
        ("built-in.ocean-blue", "OceanBlue.png", 200, 43),
        ("built-in.royal-noir", "RoyalNoir.png", 352, 29),
        ("built-in.classic-olive", "ClassicOlive.png", 378, 26)
    ]

    for (id, fileName, width, height) in expected {
        let asset = try #require(TextureAsset.builtIns.first { $0.id == id })
        #expect(asset.fileName == fileName)
        let url = try #require(TextureAssetStore.bundledURL(for: asset))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == width)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == height)
    }
}

@Test @MainActor func catalogStartsWithBundledAzureAndResolvesIt() throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }

    #expect(fixture.store.assets.first == TextureAsset.azureReflection)
    #expect(fixture.store.resolvedURL(for: TextureAsset.azureReflection.id) == fixture.azureURL)
    #expect(fixture.store.isAvailable(id: TextureAsset.azureReflection.id))
}

@Test @MainActor func importingNormalizesPersistsAndDeduplicates() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let source = try fixture.makeImage(name: "reflection", type: .jpeg, width: 32, height: 24)

    let first = try await fixture.store.importTexture(from: source)
    let second = try await fixture.store.importTexture(from: source)

    #expect(first == second)
    #expect(first.id.hasPrefix("custom."))
    #expect(first.fileName?.hasSuffix(".png") == true)
    #expect(fixture.store.customAssets.count == 1)
    #expect(fixture.store.resolvedURL(for: first.id)?.pathExtension == "png")

    let reloaded = fixture.makeReloadedStore()
    #expect(reloaded.customAssets == [first])
}

@Test @MainActor func corruptImportDoesNotMutateCatalog() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let corrupt = fixture.directory.appendingPathComponent("broken.png")
    try Data("not an image".utf8).write(to: corrupt)
    let before = fixture.store.assets

    await #expect(throws: TextureAssetStore.StoreError.self) {
        try await fixture.store.importTexture(from: corrupt)
    }
    #expect(fixture.store.assets == before)
}

@Test func bundledAzureResourceExists() {
    #expect(TextureAssetStore.bundledAzureURL() != nil)
}

@Test func classicMenuBarResourcesExistAtTheirTargetSize() throws {
    let classicIDs = [
        TextureAsset.silverGlass,
        TextureAsset.graphiteGlass,
        TextureAsset.coastalLight,
        TextureAsset.coastalDark
    ] + TextureAsset.builtIns.filter { asset in
        ["built-in.striped-light", "built-in.striped-dark"].contains(asset.id)
    }
    #expect(classicIDs.count == 6)
    for asset in classicIDs {
        let url = try #require(TextureAssetStore.bundledURL(for: asset))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2048)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 128)
    }
}

@Test func classicMenuBarTexturesAreHorizontallyUniformAndVerticallySmooth() throws {
    for asset in TextureAsset.builtIns.filter({ $0.id.contains("silver-glass")
        || $0.id.contains("graphite-glass")
        || $0.id.contains("coastal")
        || $0.id.contains("striped") }) {
        let rows = try textureRowLuminance(for: asset)
        #expect(try textureMaximumHorizontalLuminanceSpread(for: asset) < 0.1)
        let largestBodyStep = zip(rows, rows.dropFirst())
            .prefix(120)
            .map { abs($0 - $1) }
            .max() ?? 0
        #expect(largestBodyStep < 5)
    }
}

@Test func silverGlassTextureRetainsGlossProfileAfterResampling() throws {
    let rows = try textureRowLuminance(for: TextureAsset.silverGlass)
    try #require(rows.count == 128)
    #expect(rows[16] - rows[64] > 35)
    #expect(rows[64] - rows[112] > 20)
}

@Test func coastalTextureUsesASmoothDarkeningProfile() throws {
    let rows = try textureRowLuminance(for: TextureAsset.coastalLight)
    try #require(rows.count == 128)
    #expect(rows[8] - rows[48] > 15)
    #expect(rows[48] - rows[88] > 15)
    #expect(rows[88] - rows[124] > 20)
}

@Test func stripedTextureUsesATwoStageGlossProfile() throws {
    let asset = try #require(TextureAsset.builtIns.first { $0.id == "built-in.striped-light" })
    let rows = try textureRowLuminance(for: asset)
    try #require(rows.count == 128)
    #expect(rows[8] - rows[64] > 130)
    #expect(rows[104] - rows[64] > 120)
    #expect(rows[104] - rows[124] > 20)
}

@Test func darkTextureVariantsRetainTheirDistinctProfiles() throws {
    let graphite = try textureRowLuminance(for: TextureAsset.graphiteGlass)
    try #require(graphite.count == 128)
    #expect(graphite[16] - graphite[64] > 25)
    #expect(graphite[64] - graphite[124] > 10)

    let coastal = try textureRowLuminance(for: TextureAsset.coastalDark)
    try #require(coastal.count == 128)
    #expect(coastal[8] - coastal[56] > 10)
    #expect(coastal[56] - coastal[124] > 15)

    let stripedAsset = try #require(TextureAsset.builtIns.first { $0.id == "built-in.striped-dark" })
    let striped = try textureRowLuminance(for: stripedAsset)
    try #require(striped.count == 128)
    #expect(striped[8] - striped[52] > 10)
    #expect(striped[104] - striped[64] > 12)
    #expect(striped[104] - striped[124] > 15)
}

@Test @MainActor func pngJpegAndHeicImportsAreAccepted() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }

    for (index, type) in [UTType.png, .jpeg, .heic].enumerated() {
        let url = try fixture.makeImage(
            name: UUID().uuidString,
            type: type,
            width: 16 + index,
            height: 12 + index
        )
        _ = try await fixture.store.importTexture(from: url)
    }
    #expect(fixture.store.customAssets.count == 3)
}

@Test @MainActor func oversizedImportIsDownsampledTo4096() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let source = try fixture.makeImage(name: "wide", type: .png, width: 5000, height: 10)

    let asset = try await fixture.store.importTexture(from: source)
    let url = try #require(fixture.store.resolvedURL(for: asset.id))
    let sourceImage = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(sourceImage, 0, nil) as? [CFString: Any]
    )
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 4096)
}

@Test @MainActor func importNormalizesOrientationAndColorSpace() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let source = try fixture.makeImage(
        name: "rotated",
        type: .png,
        width: 30,
        height: 10,
        orientation: 6
    )

    let asset = try await fixture.store.importTexture(from: source)
    let url = try #require(fixture.store.resolvedURL(for: asset.id))
    let imageSource = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    #expect(image.width == 10)
    #expect(image.height == 30)
    #expect(image.colorSpace?.name == CGColorSpace.sRGB)
}

@Test @MainActor func missingImportedFileKeepsMetadataButDoesNotResolve() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let source = try fixture.makeImage(name: "missing", type: .png, width: 12, height: 8)
    let asset = try await fixture.store.importTexture(from: source)
    let storedURL = try #require(fixture.store.resolvedURL(for: asset.id))
    try FileManager.default.removeItem(at: storedURL)

    #expect(fixture.store.asset(id: asset.id) == asset)
    #expect(fixture.store.resolvedURL(for: asset.id) == nil)
    #expect(!fixture.store.isAvailable(id: asset.id))

    try Data("broken".utf8).write(to: storedURL)
    #expect(fixture.store.resolvedURL(for: asset.id) == nil)
    #expect(!fixture.store.isAvailable(id: asset.id))
}

@Test @MainActor func persistedMetadataContainsNoExternalPath() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let source = try fixture.makeImage(name: "private-source", type: .png, width: 14, height: 9)

    _ = try await fixture.store.importTexture(from: source)
    let storedData = try #require(fixture.defaults.data(forKey: "textures"))
    let storedText = String(decoding: storedData, as: UTF8.self)

    #expect(!storedText.contains(source.path))
    #expect(!storedText.contains(source.deletingLastPathComponent().path))
}

@Test @MainActor func packageTextureBatchDeduplicatesAndRollsBackOnlyNewContent() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let source = try fixture.makeImage(name: "existing", type: .png, width: 20, height: 10)
    let existing = try await fixture.store.importTexture(from: source)
    let existingURL = try #require(fixture.store.resolvedURL(for: existing.id))
    let existingData = try Data(contentsOf: existingURL)

    let rawNewURL = try fixture.makeImage(name: "new", type: .png, width: 18, height: 9)
    let rawNewData = try Data(contentsOf: rawNewURL)
    let newData = try TextureAssetStore.normalizeTextureData(rawNewData)
    let newDigest = SHA256.hash(data: newData)
        .map { String(format: "%02x", $0) }
        .joined()

    let receipt = try fixture.store.installPackageTextures([
        PackageTexturePayload(
            sourceID: "source-existing",
            name: "Existing",
            pngData: existingData,
            sha256: existing.id.replacingOccurrences(of: "custom.", with: "")
        ),
        PackageTexturePayload(
            sourceID: "source-new",
            name: "New",
            pngData: newData,
            sha256: newDigest
        )
    ])

    #expect(receipt.sourceToLocalID["source-existing"] == existing.id)
    #expect(fixture.store.customAssets.count == 2)
    fixture.store.rollbackPackageInstallation(receipt)
    #expect(fixture.store.customAssets == [existing])
    #expect(FileManager.default.fileExists(atPath: existingURL.path))
}

private func textureRowLuminance(for asset: TextureAsset) throws -> [Double] {
    let url = try #require(TextureAssetStore.bundledURL(for: asset))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
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

    return (0..<height).map { y in
        var total = 0.0
        for x in stride(from: 0, to: width, by: 16) {
            let offset = (y * width + x) * 4
            let red = Double(bytes[offset])
            let green = Double(bytes[offset + 1])
            let blue = Double(bytes[offset + 2])
            total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        return total / Double((width + 15) / 16)
    }
}

private func textureMaximumHorizontalLuminanceSpread(for asset: TextureAsset) throws -> Double {
    let url = try #require(TextureAssetStore.bundledURL(for: asset))
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
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

    return (0..<height).map { y in
        let luminances = stride(from: 0, to: width, by: 16).map { x in
            let offset = (y * width + x) * 4
            return 0.2126 * Double(bytes[offset])
                + 0.7152 * Double(bytes[offset + 1])
                + 0.0722 * Double(bytes[offset + 2])
        }
        return (luminances.max() ?? 0) - (luminances.min() ?? 0)
    }.max() ?? 0
}
