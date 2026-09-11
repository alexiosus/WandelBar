import AppKit
import SwiftUI
import Testing
@testable import WandelBar

@MainActor private final class SnapshotWallpaperController: WallpaperEffectControlling {
    var isEnabled = false
    var state: WandelBarState = .off
    var canCustomizeCurrentSpace = false
    var isCurrentSpaceCustomized = false
    var isCurrentSpaceEffectEnabled = true
    var dontApplyOnLockScreen = false
    func effectSettings(for scope: EffectScope) -> WallpaperEffectSettings { .default }
    func setEnabled(_ enabled: Bool) {}
    func updateEffectSettings(_ settings: WallpaperEffectSettings, for scope: EffectScope) {}
    func applySettingsChange(delay: TimeInterval) {}
    func refreshWallpaperSupport() {}
    func clearCurrentSpaceOverride() {}
    func setCurrentSpaceEffectEnabled(_ enabled: Bool) {}
    func setDontApplyOnLockScreen(_ enabled: Bool) {}
}

/// Opt-in artifact generation for manual visual review; never opens the desktop controller.
@Test(.enabled(if: ProcessInfo.processInfo.environment["WANDELBAR_QA_OUTPUT"] != nil))
@MainActor func renderNativeInterfaceSnapshots() async throws {
    guard let path = ProcessInfo.processInfo.environment["WANDELBAR_QA_OUTPUT"] else { return }
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let presets = EffectPresetStore(defaults: fixture.defaults, storageKey: "qa-presets")
    _ = try presets.createUserPreset(name: "My Glass", settings: .default)
    let model = MenuBarPopoverModel(controller: SnapshotWallpaperController(), presetStore: presets,
        textureStore: fixture.store, libraryStore: PresetLibraryStore(defaults: fixture.defaults))
    await model.preparePresetPreviews()
    try snapshot(AboutWandelBarView(), size: CGSize(width: 518, height: 270), name: "about", directory: directory)
    try snapshot(PresetCatalogView(model: model, dismiss: {}), size: CGSize(width: 360, height: 600), name: "library", directory: directory)
    let galleryService = CommunityCatalogService(configuration: .bundled(), cacheDirectory: fixture.directory.appendingPathComponent("gallery-cache"),
        transport: { _, _ in throw URLError(.notConnectedToInternet) })
    try snapshot(CommunityGalleryView(onImport: { _ in }, service: galleryService),
        size: CGSize(width: 720, height: 580), name: "gallery", directory: directory)
    try snapshot(TextureManagementView(model: model), size: CGSize(width: 520, height: 410), name: "textures", directory: directory)
    let service = PresetPackageService(presetStore: presets, textureStore: fixture.store)
    let package = fixture.directory.appendingPathComponent("test.wandelbar-presets")
    _ = try await service.export(presetIDs: presets.userPresets.map(\.id), to: package)
    let preview = try await service.prepareImport(from: package)
    defer { service.discardImport(preview) }
    try snapshot(PresetImportPreviewView(preview: preview, onImportSelection: { _ in }, onCancel: {}),
        size: CGSize(width: 520, height: 380), name: "import", directory: directory)
    model.beginPresetExportSelection()
    model.shareUsingCurrentWallpaper = true
    try snapshot(PresetExportView(model: model, onChooseDestination: {}, onCancel: {},
        title: "Share to Discussions", explanation: "Choose presets and a preview background. Sharing files are prepared in a temporary folder.",
        actionTitle: "Prepare Share", showsSharingOptions: true),
        size: CGSize(width: 460, height: 430), name: "share-options", directory: directory)
    let share = try await PresetSharingService(packages: service, textures: fixture.store)
        .prepare(presets: presets.userPresets, in: fixture.directory)
    try snapshot(PresetShareResultView(result: share), size: CGSize(width: 608, height: 520), name: "share", directory: directory)
}

@MainActor private func snapshot<V: View>(_ view: V, size: CGSize, name: String, directory: URL) throws {
    let hosting = NSHostingView(rootView: view
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = hosting
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    #expect(bitmap.pixelsWide >= Int(size.width))
    window.contentView = nil
}

@Test @MainActor func renderCommunityGalleryWithGeneratedPreviews() async throws {
    guard let path = ProcessInfo.processInfo.environment["WANDELBAR_COMMUNITY_GALLERY_QA"] else { return }
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cache = directory.appendingPathComponent("cache")
    let online = CommunityCatalogService(cacheDirectory: cache)
    let loaded = try await online.load()
    for entry in loaded.catalog.entries { _ = try await online.preview(entry) }
    let offline = CommunityCatalogService(cacheDirectory: cache, transport: { _, _ in throw URLError(.notConnectedToInternet) })
    let view = CommunityGalleryView(onImport: { _ in }, service: offline).environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 720, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(900))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("community-gallery.png"))
}
