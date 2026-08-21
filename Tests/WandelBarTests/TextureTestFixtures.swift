import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import WandelBar

enum TextureFixtureError: Error {
    case cannotCreateContext
    case cannotCreateImage
    case cannotCreateDestination
    case cannotEncode
}

func writeTextureFixtureImage(
    to url: URL,
    type: UTType,
    width: Int,
    height: Int,
    orientation: Int? = nil
) throws {
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
        throw TextureFixtureError.cannotCreateContext
    }
    let color = CGColor(
        colorSpace: colorSpace,
        components: [CGFloat(width % 251) / 255, CGFloat(height % 251) / 255, 0.65, 1]
    )!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw TextureFixtureError.cannotCreateImage
    }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        type.identifier as CFString,
        1,
        nil
    ) else {
        throw TextureFixtureError.cannotCreateDestination
    }
    let properties = orientation.map {
        [kCGImagePropertyOrientation: $0] as CFDictionary
    }
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
        throw TextureFixtureError.cannotEncode
    }
}

@MainActor
final class TextureStoreFixture {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    let texturesDirectory: URL
    let azureURL: URL
    let store: TextureAssetStore

    init() throws {
        let suiteName = "WandelBarTests.Textures.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let texturesDirectory = directory.appendingPathComponent("Textures", isDirectory: true)
        let azureURL = directory.appendingPathComponent("AzureReflection.png")
        let embeddedSlateURL = directory.appendingPathComponent("EmbeddedSlate.png")
        let classicBlueURL = directory.appendingPathComponent("ClassicBlue.png")
        let oceanBlueURL = directory.appendingPathComponent("OceanBlue.png")
        let royalNoirURL = directory.appendingPathComponent("RoyalNoir.png")
        let classicOliveURL = directory.appendingPathComponent("ClassicOlive.png")
        let silverGlassURL = directory.appendingPathComponent("SilverGlass.png")
        let graphiteGlassURL = directory.appendingPathComponent("GraphiteGlass.png")
        let coastalURL = directory.appendingPathComponent("CoastalLight.png")
        let coastalDarkURL = directory.appendingPathComponent("CoastalDark.png")
        let stripedURL = directory.appendingPathComponent("StripedLight.png")
        let stripedDarkURL = directory.appendingPathComponent("StripedDark.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeTextureFixtureImage(to: azureURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: embeddedSlateURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: classicBlueURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: oceanBlueURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: royalNoirURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: classicOliveURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: silverGlassURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: graphiteGlassURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: coastalURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: coastalDarkURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: stripedURL, type: .png, width: 8, height: 8)
        try writeTextureFixtureImage(to: stripedDarkURL, type: .png, width: 8, height: 8)
        let builtInURLs = [
            TextureAsset.azureReflection.id: azureURL,
            TextureAsset.embeddedSlate.id: embeddedSlateURL,
            TextureAsset.classicBlue.id: classicBlueURL,
            TextureAsset.oceanBlue.id: oceanBlueURL,
            TextureAsset.royalNoir.id: royalNoirURL,
            TextureAsset.classicOlive.id: classicOliveURL,
            TextureAsset.silverGlass.id: silverGlassURL,
            TextureAsset.graphiteGlass.id: graphiteGlassURL,
            TextureAsset.coastalLight.id: coastalURL,
            TextureAsset.coastalDark.id: coastalDarkURL,
            TextureAsset.stripedLight.id: stripedURL,
            TextureAsset.stripedDark.id: stripedDarkURL
        ]

        self.suiteName = suiteName
        self.defaults = defaults
        self.directory = directory
        self.texturesDirectory = texturesDirectory
        self.azureURL = azureURL
        self.store = TextureAssetStore(
            defaults: defaults,
            storageKey: "textures",
            texturesDirectory: texturesDirectory,
            builtInURL: { asset in builtInURLs[asset.id] }
        )
    }

    func makeReloadedStore() -> TextureAssetStore {
        TextureAssetStore(
            defaults: defaults,
            storageKey: "textures",
            texturesDirectory: texturesDirectory,
            builtInURL: { [azureURL] asset in
                asset.id == TextureAsset.azureReflection.id ? azureURL : nil
            }
        )
    }

    func makeImage(
        name: String,
        type: UTType,
        width: Int,
        height: Int,
        orientation: Int? = nil
    ) throws -> URL {
        let ext = type.preferredFilenameExtension ?? "img"
        let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
        try writeTextureFixtureImage(
            to: url,
            type: type,
            width: width,
            height: height,
            orientation: orientation
        )
        return url
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
