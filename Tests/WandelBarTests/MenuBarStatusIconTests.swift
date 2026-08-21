import AppKit
import Testing
@testable import WandelBar

@MainActor
@Test func statusIconDistinguishesEveryControllerState() {
    #expect(MenuBarStatusIcon.kind(for: .off) == .off)
    #expect(MenuBarStatusIcon.kind(for: .active(since: nil)) == .active)
    #expect(MenuBarStatusIcon.kind(for: .unsupported("video wallpapers are not supported")) == .unsupported)
    #expect(MenuBarStatusIcon.kind(for: .error("boom")) == .error)
}

@MainActor
@Test func statusIconIsATemplateOfMenuBarSize() {
    for kind in [MenuBarStatusIconKind.off, .active, .unsupported, .error] {
        let image = MenuBarStatusIcon.image(for: kind)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }
}

@MainActor
@Test func statusIconKeepsStableImageIdentityForTheSameState() {
    let first = MenuBarStatusIcon.image(for: .active)
    let second = MenuBarStatusIcon.image(for: .active)

    #expect(first === second)
}

/// The four states must not collapse into the same glyph; compare rendered pixels.
@MainActor
@Test func statusIconRendersADistinctGlyphPerState() {
    let kinds: [MenuBarStatusIconKind] = [.off, .active, .unsupported, .error]
    let renders = kinds.map { pngData(MenuBarStatusIcon.image(for: $0)) }

    for (index, data) in renders.enumerated() {
        #expect(data != nil, "\(kinds[index]) did not render")
    }
    #expect(Set(renders.compactMap { $0 }).count == kinds.count)
}

@MainActor
private func pngData(_ image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        return nil
    }
    return bitmap.representation(using: .png, properties: [:])
}
