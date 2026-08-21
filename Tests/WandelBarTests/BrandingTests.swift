import Foundation
import Testing

private func applicationInfoPlist() throws -> [String: Any] {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
    return try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
}

@Test func applicationUsesWandelBarIdentity() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let plist = try applicationInfoPlist()

    #expect(plist["CFBundleName"] as? String == "WandelBar")
    #expect(plist["CFBundleDisplayName"] as? String == "WandelBar")
    #expect(plist["CFBundleIdentifier"] as? String == "com.alexeremeev.WandelBar")
    #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
    #expect(plist["CFBundleIconName"] as? String == "AppIcon")
    // Without this the app is a regular LaunchServices app whose Dock tile reappears —
    // and sticks — every time it is opened again while already running.
    #expect(plist["LSUIElement"] as? Bool == true)

    let packageManifest = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    let legacyName = ["Blur", "Bar"].joined()
    #expect(packageManifest.contains("name: \"WandelBar\""))
    #expect(packageManifest.contains("name: \"WandelBarTests\""))
    #expect(!packageManifest.contains("name: \"\(legacyName)\""))

    let packagingScript = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Scripts/package_app.sh"),
        encoding: .utf8
    )
    #expect(packagingScript.contains("Build/WandelBar.app"))
    #expect(!packagingScript.contains("Build/\(legacyName).app"))
    #expect(packagingScript.contains("Assets.car"))
    #expect(packagingScript.contains("xcrun actool"))

    let iconData = try Data(contentsOf: repositoryRoot.appendingPathComponent("Resources/AppIcon.icon/icon.json"))
    let icon = try #require(JSONSerialization.jsonObject(with: iconData) as? [String: Any])
    let groups = try #require(icon["groups"] as? [[String: Any]])
    #expect(groups.count == 1)
    let layers = try #require(groups.first?["layers"] as? [[String: Any]])
    #expect(layers.count == 1)
    #expect(layers.first?["image-name"] as? String == "Background.png")
    #expect(layers.first?["glass"] as? Bool == false)
}

@Test func applicationDeclaresPresetPackageFileType() throws {
    let plist = try applicationInfoPlist()
    let declarations = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let declaration = try #require(declarations.first {
        $0["UTTypeIdentifier"] as? String == "com.alexeremeev.WandelBar.preset-package"
    })
    let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
    #expect(tags["public.filename-extension"] as? [String] == ["wandelbar-presets"])
    #expect(declaration["UTTypeConformsTo"] as? [String] == ["public.zip-archive"])
}
