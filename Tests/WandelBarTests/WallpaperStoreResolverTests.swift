import Foundation
import Testing
@testable import WandelBar

@Test func resolverNeverBorrowsWallpaperFromAnotherSpace() {
    let root: [String: Any] = [
        "Spaces": [
            "active": space(marker: "active"),
            "other": space(marker: "other")
        ],
        "SystemDefault": ["Desktop": desktop(marker: "system")]
    ]

    let candidates = WallpaperStoreResolver().desktopCandidates(
        from: root,
        displayUUID: nil,
        activeSpaceUUID: "active"
    )

    #expect(candidates.map { $0.desktop["marker"] as? String } == ["active"])
    #expect(!candidates.contains { $0.spaceUUID == "other" })
}

@Test func newActiveSpaceDoesNotUseAStaleDisplayFallback() {
    let displayUUID = "display"
    let root: [String: Any] = [
        "Spaces": [
            "second": space(marker: "second")
        ],
        "Displays": [
            displayUUID: ["Desktop": desktop(marker: "second-display-fallback")]
        ],
        "SystemDefault": ["Desktop": desktop(marker: "system")]
    ]

    let candidates = WallpaperStoreResolver().desktopCandidates(
        from: root,
        displayUUID: displayUUID,
        activeSpaceUUID: "new-space-not-written-yet"
    )

    #expect(candidates.isEmpty)
}

@Test func unresolvedActiveSpaceSkipsEverySpaceCandidate() {
    let root: [String: Any] = [
        "Spaces": [
            "first": space(marker: "first"),
            "second": space(marker: "second")
        ],
        "SystemDefault": ["Desktop": desktop(marker: "system")]
    ]

    let candidates = WallpaperStoreResolver().desktopCandidates(
        from: root,
        displayUUID: nil,
        activeSpaceUUID: nil
    )

    #expect(candidates.count == 1)
    #expect(candidates.first?.desktop["marker"] as? String == "system")
}

@Test func fullscreenSpaceUsesFirstDesktopSpaceWallpaper() {
    let display: [String: Any] = [
        "Current Space": ["uuid": "fullscreen", "type": 4],
        "Spaces": [
            ["uuid": "first-desktop", "type": 0],
            ["uuid": "second-desktop", "type": 0],
            ["uuid": "fullscreen", "type": 4]
        ]
    ]

    let context = ActiveSpaceResolver.spaceContext(fromManagedDisplay: display)

    #expect(context?.activeSpaceUUID == "fullscreen")
    #expect(context?.wallpaperSpaceUUID == "first-desktop")
    #expect(context?.isFullscreen == true)
}

@Test func desktopSpaceUsesItsOwnWallpaper() {
    let display: [String: Any] = [
        "Current Space": ["uuid": "second-desktop", "type": 0],
        "Spaces": [
            ["uuid": "first-desktop", "type": 0],
            ["uuid": "second-desktop", "type": 0]
        ]
    ]

    let context = ActiveSpaceResolver.spaceContext(fromManagedDisplay: display)

    #expect(context?.activeSpaceUUID == "second-desktop")
    #expect(context?.wallpaperSpaceUUID == "second-desktop")
    #expect(context?.isFullscreen == false)
}

@Test func lightweightIdentityParsingDoesNotPrepareTheSource() {
    let url = URL(fileURLWithPath: "/Pictures/wallpaper.jpg")
    let desktop: [String: Any] = [
        "Content": [
            "Choices": [[
                "Files": [["absolute": url.absoluteString]]
            ]]
        ]
    ]

    #expect(WallpaperStoreResolver().wallpaperIdentity(fromDesktop: desktop) == .file(url))
}

@Test func lightweightIdentityParsingPreservesPhotosAssetID() throws {
    let identifier = "8583E207-2FE2-437B-8D94-9A1082446039/L0/001"
    let configuration = try PropertyListSerialization.data(
        fromPropertyList: ["type": "asset", "identifier": identifier],
        format: .binary,
        options: 0
    )
    let desktop: [String: Any] = [
        "Content": [
            "Choices": [[
                "Provider": "com.apple.wallpaper.extension.photos",
                "Configuration": configuration
            ]]
        ]
    ]

    #expect(
        WallpaperStoreResolver().wallpaperIdentity(fromDesktop: desktop)
            == .photosAsset(identifier)
    )
}

private func space(marker: String) -> [String: Any] {
    ["Default": ["Desktop": desktop(marker: marker)]]
}

private func desktop(marker: String) -> [String: Any] {
    ["marker": marker]
}

@Test func videoWallpaperProvidersAreReportedAsUnsupported() {
    let aerials: [String: Any] = [
        "Content": [
            "Choices": [
                [
                    "Provider": "com.apple.wallpaper.choice.aerials",
                    "Configuration": Data()
                ]
            ]
        ]
    ]

    #expect(
        WallpaperStoreResolver.unsupportedWallpaperReason(fromDesktop: aerials)
            == "video wallpapers are not supported"
    )
    #expect(
        WallpaperStoreResolver.unsupportedProviderReason("com.apple.NeptuneOneExtension")
            == "video wallpapers are not supported"
    )
    #expect(
        WallpaperStoreResolver.unsupportedProviderReason("com.apple.wallpaper.choice.macintosh")
            == "animated wallpapers are not supported"
    )
}

@Test func ordinaryImageWallpapersAreNotReportedAsUnsupported() {
    let image: [String: Any] = [
        "Content": [
            "Choices": [
                [
                    "Provider": "com.apple.wallpaper.choice.image",
                    "Files": [["relative": "file:///Library/Desktop%20Pictures/Sonoma.heic"]]
                ]
            ]
        ]
    ]

    #expect(WallpaperStoreResolver.unsupportedWallpaperReason(fromDesktop: image) == nil)
    #expect(WallpaperStoreResolver.unsupportedProviderReason("com.apple.wallpaper.extension.photos") == nil)
}

@Test func aerialPlaceholderStillIsTreatedAsAVideoWallpaper() {
    // macOS hands out this symlink instead of the moving wallpaper it stands for.
    #expect(
        WallpaperStoreResolver.isDynamicWallpaperPlaceholder(
            URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
        )
    )
    #expect(
        WallpaperStoreResolver.isDynamicWallpaperPlaceholder(
            URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.heic")
        )
    )
}

@Test func ordinaryWallpaperFilesAreNotMistakenForThePlaceholder() {
    for path in [
        "/System/Library/Desktop Pictures/Big Sur.heic",
        "/Users/someone/Pictures/wallpaper.jpg",
        "/Library/Application Support/Whatever/image.png"
    ] {
        #expect(!WallpaperStoreResolver.isDynamicWallpaperPlaceholder(URL(fileURLWithPath: path)))
    }
}
