import AppKit

enum PresetSampleBackground {
    /// The full photograph is used for rendering; `image` remains a lightweight strip
    /// for the catalogue's synchronous placeholder.
    static var renderURL: URL? {
        if let source = Bundle.main.url(forResource: "PresetSampleSource", withExtension: "png", subdirectory: "Preview") { return source }
        if Bundle.main.bundleURL.pathExtension != "app",
           let source = Bundle.module.url(forResource: "PresetSampleSource", withExtension: "png", subdirectory: "Preview") { return source }
        return url
    }

    static let url = Bundle.main.url(
        forResource: "PresetSampleBackground",
        withExtension: "png",
        subdirectory: "Preview"
    ) ?? Bundle.module.url(
        forResource: "PresetSampleBackground",
        withExtension: "png",
        subdirectory: "Preview"
    )

    @MainActor
    static let image: NSImage? = url.flatMap(NSImage.init(contentsOf:))
}

struct PresetCatalogLayout: Sendable {
    let containerWidth: CGFloat
    let horizontalPadding: CGFloat
    let columnSpacing: CGFloat

    init(
        containerWidth: CGFloat,
        horizontalPadding: CGFloat = 16,
        columnSpacing: CGFloat = 10
    ) {
        self.containerWidth = containerWidth
        self.horizontalPadding = horizontalPadding
        self.columnSpacing = columnSpacing
    }

    var cardWidth: CGFloat {
        floor((containerWidth - horizontalPadding * 2 - columnSpacing) / 2)
    }

    var previewSize: CGSize {
        CGSize(width: cardWidth, height: 66)
    }
}

struct PresetControlRowLayout: Sendable {
    let availableWidth: CGFloat
    let labelWidth: CGFloat
    let selectorWidth: CGFloat
    let spacing: CGFloat

    init(
        availableWidth: CGFloat,
        labelWidth: CGFloat = 52,
        selectorWidth: CGFloat = 196,
        spacing: CGFloat = 8
    ) {
        self.availableWidth = availableWidth
        self.labelWidth = labelWidth
        self.selectorWidth = selectorWidth
        self.spacing = spacing
    }

    var contentWidth: CGFloat {
        labelWidth * 2 + selectorWidth + spacing * 2
    }

    var selectorFrame: CGRect {
        CGRect(
            x: (availableWidth - contentWidth) / 2 + labelWidth + spacing,
            y: 0,
            width: selectorWidth,
            height: 30
        )
    }
}

struct PresetCatalogSection: Identifiable, Sendable {
    let id: String
    let title: String
    let presets: [EffectPreset]

    static func make(
        builtInSections: [EffectPresetSection],
        userPresets: [EffectPreset]
    ) -> [PresetCatalogSection] {
        var sections = builtInSections.map { section in
            PresetCatalogSection(
                id: section.id,
                title: section.title,
                presets: section.presets
            )
        }
        sections.append(PresetCatalogSection(
            id: "user",
            title: "My Presets",
            presets: userPresets
        ))
        return sections
    }
}
