import AppKit
import ImageIO
import UniformTypeIdentifiers

// The standalone build supplies only the project's bundled sample photograph.
// It cannot select the runner's wallpaper or start the application.
enum PresetSampleBackground {
    static var renderURL: URL? {
        URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("Preview/PresetSampleSource.png")
    }
}

@main struct CommunityPreviewRendererTool {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let resources = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        let data = try Data(contentsOf: input.appendingPathComponent("manifest.json"))
        guard data.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let manifest = try JSONDecoder().decode(PresetPackageManifest.self, from: data)
        guard manifest.version == 1, !manifest.presets.isEmpty, manifest.presets.count <= 100 else { throw CocoaError(.fileReadCorruptFile) }
        let items = try manifest.presets.prefix(6).map { preset -> SharePreviewItem in
            let texture: URL?
            if let reference = preset.texture {
                if reference.kind == .builtIn {
                    guard let name = TextureAsset.builtIns.first(where: { $0.id == reference.id })?.fileName else { throw CocoaError(.fileReadCorruptFile) }
                    texture = resources.appendingPathComponent("Textures").appendingPathComponent(name)
                } else {
                    guard let path = reference.path, PresetPackagePath(path) != nil else { throw CocoaError(.fileReadCorruptFile) }
                    texture = input.appendingPathComponent(path)
                }
            } else { texture = nil }
            return SharePreviewItem(name: preset.name, settings: preset.settings.clamped, textureURL: texture)
        }
        var image = try SharePreviewRenderer.render(Array(items))
        while true {
        guard let encoder = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        if size <= 8 * 1024 * 1024 { break }
        guard image.width > 720, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: max(720, image.width * 3 / 4),
                height: max(1, image.height * max(720, image.width * 3 / 4) / image.width), bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteOutOfSpace) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let smaller = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        image = smaller
        }
    }
}
