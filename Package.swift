// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WandelBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WandelBar", targets: ["WandelBar"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .systemLibrary(name: "CArchive"),
        .executableTarget(
            name: "WandelBar",
            dependencies: ["CArchive", .product(name: "Sparkle", package: "Sparkle")],
            resources: [
                .copy("Resources/Preview"),
                .copy("Resources/Textures"),
                .copy("Resources/Community")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Photos"),
                .linkedFramework("QuickLookThumbnailing"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "WandelBarTests",
            dependencies: ["WandelBar"]
        )
    ]
)
