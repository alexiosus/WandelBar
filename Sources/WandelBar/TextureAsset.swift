import Foundation

struct TextureAsset: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case builtIn
        case custom
    }

    let id: String
    let name: String
    let kind: Kind
    let fileName: String?

    static let azureReflection = TextureAsset(
        id: "built-in.azure-reflection",
        name: "Azure Reflection",
        kind: .builtIn,
        fileName: "AzureReflection.png"
    )

    static let embeddedSlate = TextureAsset(
        id: "built-in.embedded-slate",
        name: "Embedded Slate",
        kind: .builtIn,
        fileName: "EmbeddedSlate.png"
    )

    static let classicBlue = TextureAsset(
        id: "built-in.classic-blue",
        name: "Classic Blue",
        kind: .builtIn,
        fileName: "ClassicBlue.png"
    )

    static let oceanBlue = TextureAsset(
        id: "built-in.ocean-blue",
        name: "Ocean Blue",
        kind: .builtIn,
        fileName: "OceanBlue.png"
    )

    static let royalNoir = TextureAsset(
        id: "built-in.royal-noir",
        name: "Royal Noir",
        kind: .builtIn,
        fileName: "RoyalNoir.png"
    )

    static let classicOlive = TextureAsset(
        id: "built-in.classic-olive",
        name: "Classic Olive",
        kind: .builtIn,
        fileName: "ClassicOlive.png"
    )

    static let silverGlass = TextureAsset(
        id: "built-in.silver-glass",
        name: "Silver Glass",
        kind: .builtIn,
        fileName: "SilverGlass.png"
    )

    static let graphiteGlass = TextureAsset(
        id: "built-in.graphite-glass",
        name: "Graphite Glass",
        kind: .builtIn,
        fileName: "GraphiteGlass.png"
    )

    static let coastalLight = TextureAsset(
        id: "built-in.coastal-light",
        name: "Coastal Light",
        kind: .builtIn,
        fileName: "CoastalLight.png"
    )

    static let coastalDark = TextureAsset(
        id: "built-in.coastal-dark",
        name: "Coastal Dark",
        kind: .builtIn,
        fileName: "CoastalDark.png"
    )

    static let stripedLight = TextureAsset(
        id: "built-in.striped-light",
        name: "Striped Light",
        kind: .builtIn,
        fileName: "StripedLight.png"
    )

    static let stripedDark = TextureAsset(
        id: "built-in.striped-dark",
        name: "Striped Dark",
        kind: .builtIn,
        fileName: "StripedDark.png"
    )

    static let builtIns = [
        azureReflection,
        oceanBlue,
        classicBlue,
        classicOlive,
        embeddedSlate,
        royalNoir,
        stripedLight,
        stripedDark,
        silverGlass,
        graphiteGlass,
        coastalLight,
        coastalDark
    ]
}
