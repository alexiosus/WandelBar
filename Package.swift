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
    targets: [
        .executableTarget(
            name: "WandelBar",
            resources: [
                .copy("Resources/Preview"),
                .copy("Resources/Textures")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Photos"),
                .linkedFramework("QuickLookThumbnailing")
            ]
        ),
        .testTarget(
            name: "WandelBarTests",
            dependencies: ["WandelBar"]
        )
    ]
)
