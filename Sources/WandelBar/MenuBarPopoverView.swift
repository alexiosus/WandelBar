import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
protocol WallpaperEffectControlling: AnyObject {
    var isEnabled: Bool { get }
    var state: WandelBarState { get }
    var canCustomizeCurrentSpace: Bool { get }
    var isCurrentSpaceCustomized: Bool { get }
    var isCurrentSpaceEffectEnabled: Bool { get }
    var dontApplyOnLockScreen: Bool { get }
    var presetPreviewMenuBarHeight: CGFloat { get }

    func effectSettings(for scope: EffectScope) -> WallpaperEffectSettings
    func setEnabled(_ enabled: Bool)
    func updateEffectSettings(_ settings: WallpaperEffectSettings, for scope: EffectScope)
    func applySettingsChange(delay: TimeInterval)
    func refreshWallpaperSupport()
    func clearCurrentSpaceOverride()
    func setCurrentSpaceEffectEnabled(_ enabled: Bool)
    func setDontApplyOnLockScreen(_ enabled: Bool)
    func presetPreviewContext() async -> PresetPreviewContext?
}

extension WallpaperEffectControlling {
    var presetPreviewMenuBarHeight: CGFloat { 24 }
    func presetPreviewContext() async -> PresetPreviewContext? { nil }
}

extension WallpaperController: WallpaperEffectControlling {}

@MainActor
final class MenuBarPopoverModel: ObservableObject {
    @Published private(set) var state: WandelBarState = .off
    @Published var isEnabled = false
    @Published var blurRadius: Double = 0
    @Published var blurLength: Double = 0
    @Published var fadeLength: Double = 0
    @Published var shadowStrengthPercent: Double = 0
    @Published var shadowLength: Double = 3
    @Published var tintColor: Color = .black
    @Published var tintStrengthPercent: Double = 0
    @Published var solidTint = false
    @Published var saturationPercent: Double = 0
    @Published var selectedTextureID: String?
    @Published var textureBlendMode: TextureBlendMode = .screen
    @Published var textureStrengthPercent: Double = 0
    @Published var textureLayoutMode: TextureLayoutMode = .fitWidth
    @Published var textureVerticalPositionPercent: Double = 0
    @Published var launchAtLogin = false
    @Published var dontApplyOnLockScreen = false
    @Published private(set) var scope: EffectScope = .global
    @Published private(set) var canCustomizeSpace = false
    @Published private(set) var isSpaceCustomized = false
    @Published private(set) var isSpaceDifferentFromDefault = false
    @Published private(set) var isCurrentSpaceEffectEnabled = true
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var presetRevision = 0
    @Published private(set) var selectedPresetID: String?
    @Published private(set) var textureImportError: String?
    @Published private(set) var textureCatalogRevision = 0
    @Published private(set) var isQuitConfirmationPresented = false
    @Published var exportPresetIDs: Set<String> = []
    @Published private(set) var importPreview: PresetPackageImportPreview?
    @Published private(set) var presetPackageError: String?
    @Published private(set) var presetPackageCompletion: String?
    @Published private(set) var presetPreviews: [String: NSImage] = [:]
    @Published private(set) var isPreparingPresetPreviews = false
    @Published private(set) var isUsingPresetPreviewFallback = false
    let presetPreviewPlaceholder: NSImage?

    /// Owns every file panel and package window. Kept weak: the presenter is retained by
    /// the menu bar controller, which also owns this model.
    weak var dialogPresenter: (any MenuBarDialogPresenting)?

    private let controller: any WallpaperEffectControlling
    private let presetStore: EffectPresetStore
    private let textureStore: TextureAssetStore
    private let presetPackageService: any PresetPackageServicing
    private let terminateApplication: () -> Void
    private var isLoadingFromController = false
    private var presetPreviewContextKey: String?
    private var latestPresetPreviewContext: PresetPreviewContext?
    private var presetSamplePreviews: [String: NSImage] = [:]
    private var presetSampleMenuBarHeight: CGFloat?
    private var presetSamplePreparationTask: Task<Void, Never>?
    private var presetSamplePreparationID: UUID?
    private var presetPreviewPreparationTask: Task<Void, Never>?
    private var presetPreviewPreparationID: UUID?

    init(
        controller: any WallpaperEffectControlling,
        presetStore: EffectPresetStore = .shared,
        textureStore: TextureAssetStore = .shared,
        presetPackageService: any PresetPackageServicing = PresetPackageService.shared,
        terminateApplication: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.controller = controller
        self.presetStore = presetStore
        self.textureStore = textureStore
        self.presetPackageService = presetPackageService
        self.terminateApplication = terminateApplication
        self.presetPreviewPlaceholder = PresetSampleBackground.image
        reloadFromController()
    }

    var builtInPresetSections: [EffectPresetSection] {
        EffectPreset.builtInSections
    }

    var presetCatalogSections: [PresetCatalogSection] {
        PresetCatalogSection.make(
            builtInSections: builtInPresetSections,
            userPresets: userPresets
        )
    }

    var userPresets: [EffectPreset] {
        presetStore.userPresets
    }

    var builtInTextures: [TextureAsset] {
        TextureAsset.builtIns
    }

    var selectedCustomTexture: TextureAsset? {
        guard let selectedTextureID,
              let asset = textureStore.asset(id: selectedTextureID),
              asset.kind == .custom,
              textureStore.isAvailable(id: selectedTextureID) else {
            return nil
        }
        return asset
    }

    var isTextureActive: Bool {
        selectedTextureID != nil
    }

    var selectedTextureName: String {
        guard let selectedTextureID else { return "None" }
        guard let asset = textureStore.asset(id: selectedTextureID),
              textureStore.isAvailable(id: selectedTextureID) else {
            return "Missing Texture"
        }
        return asset.name
    }

    var activePreset: EffectPreset? {
        if let selectedPresetID,
           let selected = presetStore.preset(id: selectedPresetID),
           selected.settings.matchesPresetSettings(displayedSettings) {
            return selected
        }
        return presetStore.matchingPreset(for: displayedSettings)
    }

    var activePresetName: String {
        activePreset?.name ?? "Custom"
    }

    var isEffectEditorEnabled: Bool {
        scope != .currentSpace || isCurrentSpaceEffectEnabled
    }

    func preparePresetCatalogForPresentation() async {
        await preparePresetPreviews()
    }

    private func preparePresetSamplePreviews() async {
        if let presetSamplePreparationTask {
            await presetSamplePreparationTask.value
            return
        }

        let preparationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await renderPresetSamplePreviews()
        }
        presetSamplePreparationID = preparationID
        presetSamplePreparationTask = task
        await task.value
        if presetSamplePreparationID == preparationID {
            presetSamplePreparationID = nil
            presetSamplePreparationTask = nil
        }
    }

    func preparePresetPreviews() async {
        if let presetPreviewPreparationTask {
            await presetPreviewPreparationTask.value
            return
        }

        let preparationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            isPreparingPresetPreviews = true
            defer { isPreparingPresetPreviews = false }
            await performPresetPreviewPreparation()
        }
        presetPreviewPreparationID = preparationID
        presetPreviewPreparationTask = task
        await task.value
        if presetPreviewPreparationID == preparationID {
            presetPreviewPreparationID = nil
            presetPreviewPreparationTask = nil
        }
    }

    private func performPresetPreviewPreparation() async {
        await preparePresetSamplePreviews()
        guard !Task.isCancelled else { return }

        let sampleMenuBarHeight = max(24, controller.presetPreviewMenuBarHeight)
        let fallbackCacheKey = "preset-sample-background-v2-\(sampleMenuBarHeight)"
        var presets = presetCatalogSections.flatMap(\.presets)
        if let activeID = activePreset?.id,
           let activeIndex = presets.firstIndex(where: { $0.id == activeID }) {
            presets.insert(presets.remove(at: activeIndex), at: 0)
        }

        let context = await controller.presetPreviewContext()
        latestPresetPreviewContext = context
        guard let context else {
            isUsingPresetPreviewFallback = true
            presetPreviewContextKey = fallbackCacheKey
            presetPreviews = presetSamplePreviews
            return
        }

        isUsingPresetPreviewFallback = false
        let hasEveryPreview = presets.allSatisfy { presetPreviews[$0.id] != nil }
        if presetPreviewContextKey == context.cacheKey, hasEveryPreview {
            return
        }

        presetPreviewContextKey = context.cacheKey
        presetPreviews = presetSamplePreviews
        for preset in presets {
            guard !Task.isCancelled else { return }
            let textureURL = textureStore.resolvedURL(for: preset.settings.textureID)
            let rendered = try? await Task.detached(priority: .utility) {
                try WallpaperRenderer().renderPreview(
                    sourceURL: context.sourceURL,
                    display: context.display,
                    desktopOptions: context.storedDesktop.renderOptions,
                    settings: preset.settings,
                    textureURL: textureURL,
                    size: CGSize(width: 360, height: 128)
                )
            }.value
            guard let rendered, !Task.isCancelled else {
                isUsingPresetPreviewFallback = true
                presetPreviewContextKey = fallbackCacheKey
                presetPreviews = presetSamplePreviews
                return
            }
            presetPreviews[preset.id] = NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            )
        }
    }

    private func renderPresetSamplePreviews() async {
        let sampleMenuBarHeight = max(24, controller.presetPreviewMenuBarHeight)
        if presetSampleMenuBarHeight != sampleMenuBarHeight {
            presetSampleMenuBarHeight = sampleMenuBarHeight
            presetSamplePreviews.removeAll(keepingCapacity: true)
            if presetPreviewContextKey?.hasPrefix("preset-sample-background-") == true {
                presetPreviews.removeAll(keepingCapacity: true)
            }
        }
        var presets = presetCatalogSections.flatMap(\.presets)
        if let activeID = activePreset?.id,
           let activeIndex = presets.firstIndex(where: { $0.id == activeID }) {
            presets.insert(presets.remove(at: activeIndex), at: 0)
        }

        // Prepare treated sample cards before asking macOS for the wallpaper. Accessing a
        // protected wallpaper folder can display a permission dialog; the catalog must
        // remain useful while that dialog is waiting for an answer.
        for preset in presets where presetSamplePreviews[preset.id] == nil {
            guard !Task.isCancelled else { return }
            let textureURL = textureStore.resolvedURL(for: preset.settings.textureID)
            let rendered = try? await Task.detached(priority: .utility) {
                try WallpaperRenderer().renderSamplePreview(
                    settings: preset.settings,
                    textureURL: textureURL,
                    menuBarHeightPoints: sampleMenuBarHeight,
                    size: CGSize(width: 360, height: 128)
                )
            }.value
            guard let rendered, !Task.isCancelled else { continue }
            let image = NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            )
            presetSamplePreviews[preset.id] = image
            if presetPreviews[preset.id] == nil {
                presetPreviews[preset.id] = image
            }
        }
    }

    var activeUserPreset: EffectPreset? {
        guard activePreset?.kind == .user else { return nil }
        return activePreset
    }

    var errorMessage: String? {
        if case .error(let message) = state {
            return message
        }
        return launchAtLoginError
    }

    /// A non-failure explanation for why nothing was applied, such as a video wallpaper.
    var noticeMessage: String? {
        guard case .unsupported(let message) = state else { return nil }
        return message.prefix(1).uppercased() + message.dropFirst()
    }

    func reloadFromController() {
        isLoadingFromController = true
        isEnabled = controller.isEnabled
        state = controller.state

        loadSpaceCustomizationState()
        if scope == .currentSpace && !canCustomizeSpace {
            scope = .global
        }

        loadSettings()
        launchAtLogin = Self.isLaunchAtLoginEnabled
        dontApplyOnLockScreen = controller.dontApplyOnLockScreen
        isLoadingFromController = false
    }

    /// Chooses the tab that reflects what is applied to this Space, then loads it.
    func prepareForDisplay() {
        // The wallpaper can have changed while the popover was closed.
        controller.refreshWallpaperSupport()

        let displayedScope: EffectScope = (controller.canCustomizeCurrentSpace && controller.isCurrentSpaceCustomized)
            ? .currentSpace
            : .global
        if scope != displayedScope {
            selectedPresetID = nil
        }
        scope = displayedScope
        reloadFromController()
    }

    func setScope(_ newScope: EffectScope) {
        guard scope != newScope else { return }
        scope = newScope
        selectedPresetID = nil
        reloadFromController()
    }

    private func loadSettings() {
        let settings = controller.effectSettings(for: scope)
        blurRadius = settings.blurRadiusPoints
        blurLength = settings.blurLengthPoints
        fadeLength = settings.fadeLengthPoints
        shadowStrengthPercent = settings.shadowStrength * 100
        shadowLength = settings.shadowLengthPoints
        tintColor = Self.color(from: settings.tintColor)
        tintStrengthPercent = settings.tintStrength * 100
        solidTint = settings.solidTint
        saturationPercent = settings.saturation * 100
        selectedTextureID = settings.textureID
        textureBlendMode = settings.textureBlendMode
        textureStrengthPercent = settings.textureStrength * 100
        textureLayoutMode = settings.textureLayoutMode
        textureVerticalPositionPercent = settings.textureVerticalPosition * 100
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        controller.setEnabled(enabled)
        reloadFromController()
    }

    func setCurrentSpaceEffectEnabled(_ enabled: Bool) {
        guard canCustomizeSpace, isCurrentSpaceEffectEnabled != enabled else { return }
        controller.setCurrentSpaceEffectEnabled(enabled)
        reloadFromController()
    }

    func setBlurRadius(_ value: Double) {
        blurRadius = value
        applySettings(delay: 0.3)
    }

    func setBlurLength(_ value: Double) {
        blurLength = value
        applySettings(delay: 0.3)
    }

    func setFadeLength(_ value: Double) {
        fadeLength = value
        applySettings(delay: 0.3)
    }

    func setShadowStrength(_ value: Double) {
        shadowStrengthPercent = value
        applySettings(delay: 0.3)
    }

    func setShadowLength(_ value: Double) {
        shadowLength = value
        applySettings(delay: 0.3)
    }

    func setTintColor(_ value: Color) {
        tintColor = value
        applySettings(delay: 0.3)
    }

    func setTintStrength(_ value: Double) {
        tintStrengthPercent = value
        applySettings(delay: 0.3)
    }

    func setSolidTint(_ value: Bool) {
        solidTint = value
        applySettings(delay: 0)
    }

    func setSaturation(_ value: Double) {
        saturationPercent = normalizedSaturationPercent(value)
        applySettings(delay: 0.3)
    }

    func selectTexture(id: String?) {
        selectedTextureID = id
        if id != nil && textureStrengthPercent == 0 {
            textureBlendMode = .screen
            textureStrengthPercent = 45
        }
        applySettings(delay: 0)
    }

    func setTextureBlendMode(_ mode: TextureBlendMode) {
        textureBlendMode = mode
        applySettings(delay: 0)
    }

    func setTextureStrength(_ value: Double) {
        textureStrengthPercent = value
        applySettings(delay: 0.3)
    }

    func setTextureLayoutMode(_ mode: TextureLayoutMode) {
        textureLayoutMode = mode
        applySettings(delay: 0)
    }

    func setTextureVerticalPosition(_ value: Double) {
        textureVerticalPositionPercent = value
        applySettings(delay: 0.3)
    }

    func importTexture(from url: URL) async {
        do {
            let asset = try await textureStore.importTexture(from: url)
            textureCatalogRevision &+= 1
            textureImportError = nil
            selectTexture(id: asset.id)
        } catch {
            textureImportError = error.localizedDescription
        }
    }

    func clearTextureImportError() {
        textureImportError = nil
    }

    func resetSettings() {
        selectedPresetID = nil
        switch scope {
        case .global:
            controller.updateEffectSettings(.default, for: .global)
            controller.applySettingsChange(delay: 0)
        case .currentSpace:
            controller.clearCurrentSpaceOverride()
        }
        reloadFromController()
    }

    func applyPreset(id: String) {
        guard let preset = presetStore.preset(id: id) else { return }
        selectedPresetID = preset.id
        controller.updateEffectSettings(preset.settings, for: scope)
        controller.applySettingsChange(delay: 0)
        reloadFromController()
    }

    @discardableResult
    func saveCurrentPreset(name: String) throws -> EffectPreset {
        try publishCurrentPreset(
            name: name,
            settings: displayedSettings,
            preparedPreview: nil,
            invalidatePreviewContext: true
        )
    }

    @discardableResult
    func saveCurrentPresetWithPreparedPreview(name: String) async throws -> EffectPreset {
        let settings = displayedSettings
        let preparedPreview = await preparePreview(for: settings)
        return try publishCurrentPreset(
            name: name,
            settings: settings,
            preparedPreview: preparedPreview,
            invalidatePreviewContext: preparedPreview == nil
        )
    }

    private func publishCurrentPreset(
        name: String,
        settings: WallpaperEffectSettings,
        preparedPreview: NSImage?,
        invalidatePreviewContext: Bool
    ) throws -> EffectPreset {
        let preset = try presetStore.createUserPreset(name: name, settings: settings)
        if let preparedPreview {
            presetPreviews[preset.id] = preparedPreview
        }
        selectedPresetID = preset.id
        if invalidatePreviewContext {
            presetPreviewContextKey = nil
        }
        presetRevision &+= 1
        return preset
    }

    private func preparePreview(for settings: WallpaperEffectSettings) async -> NSImage? {
        let context = latestPresetPreviewContext
        let textureURL = textureStore.resolvedURL(for: settings.textureID)
        let menuBarHeight = max(24, controller.presetPreviewMenuBarHeight)
        let rendered = await Task.detached(priority: .utility) { () -> CGImage? in
            let renderer = WallpaperRenderer()
            if let context,
               let preview = try? renderer.renderPreview(
                   sourceURL: context.sourceURL,
                   display: context.display,
                   desktopOptions: context.storedDesktop.renderOptions,
                   settings: settings,
                   textureURL: textureURL,
                   size: CGSize(width: 360, height: 128)
               ) {
                return preview
            }
            return try? renderer.renderSamplePreview(
                settings: settings,
                textureURL: textureURL,
                menuBarHeightPoints: menuBarHeight,
                size: CGSize(width: 360, height: 128)
            )
        }.value
        guard let rendered else { return nil }
        return NSImage(
            cgImage: rendered,
            size: NSSize(width: rendered.width, height: rendered.height)
        )
    }

    @discardableResult
    func replacePreset(id: String) throws -> EffectPreset {
        let preset = try presetStore.replaceUserPreset(id: id, settings: displayedSettings)
        selectedPresetID = preset.id
        presetSamplePreviews.removeValue(forKey: preset.id)
        presetPreviews.removeValue(forKey: preset.id)
        presetPreviewContextKey = nil
        presetRevision &+= 1
        return preset
    }

    func renamePreset(id: String, to name: String) throws {
        try presetStore.renameUserPreset(id: id, name: name)
        presetRevision &+= 1
    }

    func deletePreset(id: String) throws {
        try presetStore.deleteUserPreset(id: id)
        if selectedPresetID == id {
            selectedPresetID = nil
        }
        presetSamplePreviews.removeValue(forKey: id)
        presetPreviews.removeValue(forKey: id)
        presetRevision &+= 1
    }

    func renameActivePreset(to name: String) throws {
        guard let activeUserPreset else {
            throw EffectPresetStore.StoreError.presetNotFound
        }
        try renamePreset(id: activeUserPreset.id, to: name)
    }

    func deleteActivePreset() throws {
        guard let activeUserPreset else {
            throw EffectPresetStore.StoreError.presetNotFound
        }
        try deletePreset(id: activeUserPreset.id)
    }

    func requestTextureImport() {
        dialogPresenter?.presentTextureImport()
    }

    func requestPresetImport() {
        dialogPresenter?.presentPresetImport()
    }

    func requestPresetExport() {
        dialogPresenter?.presentPresetExport()
    }

    func beginPresetExportSelection() {
        presetPackageError = nil
        presetPackageCompletion = nil
        if let activeUserPreset {
            exportPresetIDs = [activeUserPreset.id]
        } else {
            exportPresetIDs = Set(userPresets.map(\.id))
        }
    }

    func setPresetSelectedForExport(_ id: String, selected: Bool) {
        if selected {
            exportPresetIDs.insert(id)
        } else {
            exportPresetIDs.remove(id)
        }
    }

    func exportSelectedPresets(to destinationURL: URL) async {
        presetPackageError = nil
        presetPackageCompletion = nil
        do {
            let result = try await presetPackageService.export(
                presetIDs: userPresets.filter { exportPresetIDs.contains($0.id) }.map(\.id),
                to: destinationURL
            )
            presetPackageCompletion = Self.exportSummary(result)
        } catch {
            presetPackageError = error.localizedDescription
        }
    }

    func preparePresetImport(from packageURL: URL) async {
        presetPackageError = nil
        presetPackageCompletion = nil
        if let importPreview { presetPackageService.discardImport(importPreview) }
        importPreview = nil
        do {
            importPreview = try await presetPackageService.prepareImport(from: packageURL)
        } catch {
            presetPackageError = error.localizedDescription
        }
    }

    func commitPresetImport() {
        guard let preview = importPreview else { return }
        presetPackageError = nil
        presetPackageCompletion = nil
        do {
            let result = try presetPackageService.commitImport(preview)
            importPreview = nil
            presetRevision &+= 1
            textureCatalogRevision &+= 1
            presetPackageCompletion = Self.importSummary(result)
        } catch {
            importPreview = nil
            presetPackageError = error.localizedDescription
        }
    }

    func cancelPresetImport() {
        guard let preview = importPreview else { return }
        presetPackageService.discardImport(preview)
        importPreview = nil
    }

    func clearPresetPackageMessage() {
        presetPackageError = nil
        presetPackageCompletion = nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isLoadingFromController else { return }
        launchAtLogin = enabled

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            // Revert the toggle to reflect the actual (unchanged) state.
            launchAtLogin = Self.isLaunchAtLoginEnabled
            launchAtLoginError = "Launch at Login could not be updated: \(error.localizedDescription)"
        }
    }

    func setDontApplyOnLockScreen(_ enabled: Bool) {
        guard !isLoadingFromController else { return }
        dontApplyOnLockScreen = enabled
        controller.setDontApplyOnLockScreen(enabled)
    }

    func requestQuit() {
        if isEnabled {
            isQuitConfirmationPresented = true
        } else {
            terminateApplication()
        }
    }

    func turnOffAndQuit() {
        isQuitConfirmationPresented = false
        setEnabled(false)
        terminateApplication()
    }

    func keepBarAndQuit() {
        isQuitConfirmationPresented = false
        terminateApplication()
    }

    func cancelQuit() {
        isQuitConfirmationPresented = false
    }

    private static var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private static func exportSummary(_ result: PresetPackageExportSummary) -> String {
        var parts = ["Exported \(result.presetCount) preset\(result.presetCount == 1 ? "" : "s")"]
        if result.textureCount > 0 {
            parts.append("\(result.textureCount) texture\(result.textureCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " and ") + "."
    }

    private static func importSummary(_ result: PresetPackageImportResult) -> String {
        var parts = ["Imported \(result.presetCount) preset\(result.presetCount == 1 ? "" : "s")"]
        if result.newTextureCount > 0 {
            parts.append("\(result.newTextureCount) new texture\(result.newTextureCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " and ") + "."
    }

    private func applySettings(delay: TimeInterval) {
        guard !isLoadingFromController else { return }

        controller.updateEffectSettings(displayedSettings, for: scope)
        controller.applySettingsChange(delay: delay)
        // Editing the This Space tab forks a per-Space override on first change.
        loadSpaceCustomizationState()
        state = controller.state
    }

    private func loadSpaceCustomizationState() {
        canCustomizeSpace = controller.canCustomizeCurrentSpace
        isSpaceCustomized = controller.isCurrentSpaceCustomized
        isCurrentSpaceEffectEnabled = controller.isCurrentSpaceEffectEnabled
        isSpaceDifferentFromDefault = isSpaceCustomized
            && (!isCurrentSpaceEffectEnabled
                || controller.effectSettings(for: .currentSpace) != controller.effectSettings(for: .global))
    }

    private var displayedSettings: WallpaperEffectSettings {
        WallpaperEffectSettings(
            blurRadiusPoints: blurRadius,
            blurLengthPoints: blurLength,
            fadeLengthPoints: fadeLength,
            shadowStrength: shadowStrengthPercent / 100,
            shadowLengthPoints: shadowLength,
            tintStrength: tintStrengthPercent / 100,
            tintColor: Self.tintColor(from: tintColor),
            solidTint: solidTint,
            saturation: saturationPercent / 100,
            textureID: selectedTextureID,
            textureBlendMode: textureBlendMode,
            textureStrength: textureStrengthPercent / 100,
            textureLayoutMode: textureLayoutMode,
            textureVerticalPosition: textureVerticalPositionPercent / 100
        ).clamped
    }

    private func normalizedSaturationPercent(_ value: Double) -> Double {
        abs(value) < 0.5 ? 0 : value
    }

    private static func tintColor(from color: Color) -> TintColor {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return TintColor(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent)
        )
    }

    private static func color(from tint: TintColor) -> Color {
        Color(.sRGB, red: tint.red, green: tint.green, blue: tint.blue)
    }
}

struct MenuBarPopoverView: View {
    @ObservedObject var model: MenuBarPopoverModel
    @State private var effectGroupDisclosureState = EffectGroupDisclosureState()
    @State private var isPresetCatalogPresented = false
    @State private var isPresetSelectionHovered = false

    var body: some View {
        rootContent
            .frame(width: 360)
            .onAppear {
                model.prepareForDisplay()
            }
            .task(id: model.presetRevision) {
                await model.preparePresetPreviews()
            }
            .alert("Texture Error", isPresented: Binding(
                get: { model.textureImportError != nil },
                set: { if !$0 { model.clearTextureImportError() } }
            )) {
                Button("OK") {
                    model.clearTextureImportError()
                }
            } message: {
                Text(model.textureImportError ?? "The texture could not be imported.")
            }
            .alert("Quit WandelBar?", isPresented: Binding(
                get: { model.isQuitConfirmationPresented },
                set: { if !$0 { model.cancelQuit() } }
            )) {
                Button("Turn Off & Quit") {
                    model.turnOffAndQuit()
                }
                Button("Keep Bar & Quit", role: .destructive) {
                    model.keepBarAndQuit()
                }
                Button("Cancel", role: .cancel) {
                    model.cancelQuit()
                }
            } message: {
                Text(quitConfirmationMessage)
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch PopoverContentSizing.presentation(
            isPresetCatalogPresented: isPresetCatalogPresented
        ) {
        case .settings:
            settingsContent
        case .presetCatalog(let height):
            PresetCatalogView(model: model) {
                isPresetCatalogPresented = false
            }
            .frame(height: height)
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
            } else if let noticeMessage = model.noticeMessage {
                noticeBanner(noticeMessage)
            }

            // The scope picker chooses which profile every control below edits, so it
            // sits with the header context rather than in the slider group.
            if model.canCustomizeSpace {
                scopePicker
                    .padding(.horizontal, 16)
                    .padding(.bottom, ScopeCustomizationIndicatorLayout().bottomSpacing)
            }

            if model.scope == .currentSpace {
                spaceApplicationToggle
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            presetRow
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .disabled(!model.isEffectEditorEnabled)
                .opacity(model.isEffectEditorEnabled ? 1 : 0.5)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                settingsDisclosure(
                    title: "Panel",
                    summary: panelSummary,
                    isExpanded: $effectGroupDisclosureState.isPanelExpanded
                ) {
                    sliderRow(
                        title: "Blur",
                        value: Binding(
                            get: { model.blurRadius },
                            set: { model.setBlurRadius($0) }
                        ),
                        range: 0...30,
                        displayValue: percentDisplay(model.blurRadius, in: 0...30)
                    )

                    sliderRow(
                        title: "Band Height",
                        value: Binding(
                            get: { model.blurLength },
                            set: { model.setBlurLength($0) }
                        ),
                        range: 0...260,
                        displayValue: pointDisplay(model.blurLength)
                    )

                    sliderRow(
                        title: "Edge Fade",
                        value: Binding(
                            get: { model.fadeLength },
                            set: { model.setFadeLength($0) }
                        ),
                        range: 0...160,
                        displayValue: pointDisplay(model.fadeLength)
                    )
                }

                if model.fadeLength == 0 {
                    settingsDivider

                    settingsDisclosure(
                        title: "Shadow",
                        summary: shadowSummary,
                        isExpanded: $effectGroupDisclosureState.isShadowExpanded
                    ) {
                        sliderRow(
                            title: "Strength",
                            accessibilityLabel: "Shadow strength",
                            value: Binding(
                                get: { model.shadowStrengthPercent },
                                set: { model.setShadowStrength($0) }
                            ),
                            range: 0...100,
                            displayValue: "\(Int(round(model.shadowStrengthPercent)))%"
                        )

                        sliderRow(
                            title: "Length",
                            accessibilityLabel: "Shadow length",
                            value: Binding(
                                get: { model.shadowLength },
                                set: { model.setShadowLength($0) }
                            ),
                            range: 0...32,
                            displayValue: pointDisplay(model.shadowLength)
                        )
                    }
                }

                settingsDivider

                settingsDisclosure(
                    title: "Tint",
                    summary: tintSummary,
                    isExpanded: $effectGroupDisclosureState.isTintExpanded
                ) {
                    tintModeRow

                    tintRow

                    sliderRow(
                        title: "Saturation",
                        value: Binding(
                            get: { model.saturationPercent },
                            set: { model.setSaturation($0) }
                        ),
                        range: -100...100,
                        displayValue: saturationDisplay,
                        fillFrom: 0
                    )
                }

                settingsDivider

                settingsDisclosure(
                    title: "Texture",
                    summary: textureSummary,
                    isExpanded: $effectGroupDisclosureState.isTextureExpanded
                ) {
                    textureControls
                }
            }
            .padding(16)
            .disabled(!model.isEffectEditorEnabled)
            .opacity(model.isEffectEditorEnabled ? 1 : 0.5)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Don't Apply on Lock Screen", isOn: Binding(
                    get: { model.dontApplyOnLockScreen },
                    set: { model.setDontApplyOnLockScreen($0) }
                ))
                .toggleStyle(.switch)

                HStack {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(.switch)

                    Spacer()

                    Button {
                        model.requestQuit()
                    } label: {
                        Label("Quit", systemImage: "power")
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var scopePicker: some View {
        let indicatorLayout = ScopeCustomizationIndicatorLayout()
        return ZStack {
            Picker("Settings Scope", selection: Binding(
                get: { model.scope },
                set: { model.setScope($0) }
            )) {
                Text("Default").tag(EffectScope.global)
                Text("This Space").tag(EffectScope.currentSpace)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .overlay {
                if scopeCustomizationPresentation.showsSpaceIndicator {
                    GeometryReader { geometry in
                        let frame = indicatorLayout.indicatorFrame(for: geometry.size)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .accessibilityHint("Default applies to Spaces without their own settings")
            .help("Default is used by Spaces that do not have their own customization.")

            HStack {
                Spacer()

                Button {
                    model.resetSettings()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!scopeCustomizationPresentation.canReset)
                .accessibilityLabel(scopeCustomizationPresentation.resetAccessibilityLabel)
                .help(scopeCustomizationPresentation.resetAccessibilityLabel)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var spaceApplicationToggle: some View {
        let layout = SpaceApplicationRowLayout(availableWidth: 328)
        return Toggle(isOn: Binding(
            get: { model.isCurrentSpaceEffectEnabled },
            set: { model.setCurrentSpaceEffectEnabled($0) }
        )) {
            Text("Apply on This Space")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(
            width: layout.availableWidth,
            height: layout.rowHeight(isEffectEnabled: model.isCurrentSpaceEffectEnabled)
        )
        .help("Turn off WandelBar for this Space without changing its settings.")
    }

    private var presetRow: some View {
        let layout = PresetControlRowLayout(availableWidth: 328)
        return HStack(spacing: layout.spacing) {
            Text("Preset")
                .frame(width: layout.labelWidth, alignment: .trailing)

            presetSelectionMenu
                .frame(width: layout.selectorWidth)

            Color.clear
                .frame(width: layout.labelWidth)
                .accessibilityHidden(true)
        }
        .frame(width: layout.contentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var presetSelectionMenu: some View {
        Button {
            Task { @MainActor in
                await model.preparePresetPreviews()
                guard !Task.isCancelled else { return }
                isPresetCatalogPresented = true
            }
        } label: {
            ZStack {
                Text(model.activePresetName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 18)

                HStack {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isPresetSelectionHovered ? 0.10 : 0.065))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering in
            isPresetSelectionHovered = hovering
        }
        .accessibilityLabel("Preset")
        .accessibilityValue(model.activePresetName)
        .accessibilityHint("Opens the preset catalog")
    }

    @ViewBuilder
    private var textureControls: some View {
        HStack(spacing: 12) {
            Text("Image")
                .frame(width: labelColumnWidth, alignment: .trailing)

            Menu {
                Button("None") {
                    model.selectTexture(id: nil)
                }

                Section("Built-in") {
                    ForEach(model.builtInTextures) { texture in
                        Button(texture.name) {
                            model.selectTexture(id: texture.id)
                        }
                    }
                }

                if let texture = model.selectedCustomTexture {
                    Section("Selected Image") {
                        Button(texture.name) {
                            model.selectTexture(id: texture.id)
                        }
                    }
                }

                Divider()
                Button("Choose Image…") {
                    model.requestTextureImport()
                }
            } label: {
                Text(model.selectedTextureName)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Texture")

            Color.clear
                .frame(width: valueColumnWidth, height: 1)
        }

        HStack(spacing: 12) {
            Text("Blend")
                .frame(width: labelColumnWidth, alignment: .trailing)

            Picker("Blend Mode", selection: Binding(
                get: { model.textureBlendMode },
                set: { model.setTextureBlendMode($0) }
            )) {
                ForEach(TextureBlendMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: valueColumnWidth, height: 1)
        }
        .disabled(!model.isTextureActive)

        HStack(spacing: 12) {
            Text("Layout")
                .frame(width: labelColumnWidth, alignment: .trailing)

            Picker("Texture Layout", selection: Binding(
                get: { model.textureLayoutMode },
                set: { model.setTextureLayoutMode($0) }
            )) {
                ForEach(TextureLayoutMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Color.clear
                .frame(width: valueColumnWidth, height: 1)
        }
        .disabled(!model.isTextureActive)

        if model.textureLayoutMode.usesVerticalPosition {
            sliderRow(
                title: "Position",
                accessibilityLabel: "Texture vertical position",
                value: Binding(
                    get: { model.textureVerticalPositionPercent },
                    set: { model.setTextureVerticalPosition($0) }
                ),
                range: -100...100,
                displayValue: texturePositionDisplay
            )
            .disabled(!model.isTextureActive)
        }

        sliderRow(
            title: "Strength",
            accessibilityLabel: "Texture strength",
            value: Binding(
                get: { model.textureStrengthPercent },
                set: { model.setTextureStrength($0) }
            ),
            range: 0...100,
            displayValue: "\(Int(model.textureStrengthPercent.rounded()))%"
        )
        .disabled(!model.isTextureActive)
    }

    private var settingsDivider: some View {
        Divider()
            .padding(.vertical, 2)
    }

    private func settingsDisclosure<Content: View>(
        title: String,
        summary: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Text(title)
                        .fontWeight(.medium)

                    Spacer(minLength: 8)

                    Text(summary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue("\(summary), \(isExpanded.wrappedValue ? "expanded" : "collapsed")")
            .accessibilityHint(isExpanded.wrappedValue ? "Collapses this section" : "Expands this section")

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.top, 12)
            }
        }
    }

    private var shadowSummary: String {
        guard model.shadowStrengthPercent >= 0.5 else { return "Off" }
        return "\(Int(round(model.shadowStrengthPercent)))% · \(pointDisplay(model.shadowLength))"
    }

    private var panelSummary: String {
        "\(percentDisplay(model.blurRadius, in: 0...30)) · "
            + "\(pointDisplay(model.blurLength)) · \(pointDisplay(model.fadeLength))"
    }

    private var tintSummary: String {
        guard model.tintStrengthPercent >= 0.5 else { return "Off" }
        let style = model.solidTint ? "Solid" : "Gradient"
        return "\(style) · \(Int(round(model.tintStrengthPercent)))%"
    }

    private var textureSummary: String {
        guard model.isTextureActive else { return "None" }
        return "\(model.selectedTextureName) · \(Int(round(model.textureStrengthPercent)))%"
    }

    private var scopeCustomizationPresentation: ScopeCustomizationPresentation {
        ScopeCustomizationPresentation(
            scope: model.scope,
            hasSpaceOverride: model.isSpaceCustomized,
            isSpaceDifferentFromDefault: model.isSpaceDifferentFromDefault
        )
    }

    private var quitConfirmationMessage: String {
        let message = "WandelBar is currently applying a customized bar. Choose whether to keep it or turn it off before quitting."
        guard model.dontApplyOnLockScreen else { return message }
        return message + " “Don’t Apply on Lock Screen” works only while WandelBar is running."
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Same drawn glyph as the status item, so the popover and the menu bar
            // always show the state with one shape.
            Image(nsImage: MenuBarStatusIcon.image(for: model.state))
                .renderingMode(.template)
                .resizable()
                .frame(width: 22, height: 22)
                .foregroundStyle(headerTint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("WandelBar")
                    .font(.headline)
                Text(statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Toggle("Enable WandelBar", isOn: Binding(
                get: { model.isEnabled },
                set: { model.setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("Enable WandelBar globally")
            .help("Enable or disable WandelBar on every Space")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var headerTint: Color {
        switch model.state {
        case .error:
            return .orange
        case .active:
            return .blue
        default:
            return .secondary
        }
    }

    // The scope picker sits directly below the header and already names the active
    // profile, so the subtitle would only echo it — keep it to a plain On/Off state.
    private var statusSummary: String {
        switch model.state {
        case .error:
            return "Error"
        case .unsupported:
            return "Not applied"
        case .active:
            return "On"
        case .off:
            return "Off"
        }
    }

    private var saturationDisplay: String {
        let value = Int(round(model.saturationPercent))
        if value > 0 {
            return "+\(value)%"
        }
        return "\(value)%"
    }

    private var texturePositionDisplay: String {
        let value = Int(model.textureVerticalPositionPercent.rounded())
        if abs(value) < 1 { return "Center" }
        if value == 100 { return "Top" }
        if value == -100 { return "Bottom" }
        return value > 0 ? "↑ \(value)%" : "↓ \(-value)%"
    }

    // Blur is a strength dial with no meaningful unit, so surface it as a share of its
    // own range — same "%" vocabulary as Tint and Saturation.
    private func percentDisplay(_ value: Double, in range: ClosedRange<Double>) -> String {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return "0%" }
        let fraction = (value - range.lowerBound) / span
        return "\(Int(round(fraction * 100)))%"
    }

    // Geometry is stored and rendered in macOS points. Showing the real unit avoids
    // implying device-pixel precision on Retina displays.
    private func pointDisplay(_ value: Double) -> String {
        "\(Int(round(value))) pt"
    }

    // Shared column widths so every row lines up: a label column and a trailing value
    // column. The Tint row's color well sits in that same value column, aligned under
    // the percentages.
    private let labelColumnWidth: CGFloat = 76
    private let valueColumnWidth: CGFloat = 52

    // Gradient = fading wash (wallpaper always shows through); Solid = uniform layer
    // that reaches a fully opaque color at 100%.
    private var tintModeRow: some View {
        // Mode and color describe *what* the tint is; Strength is *how much*. They stay
        // interactive regardless of strength so a user can set them up before dialing the
        // effect in — disabling this leading row would make the whole group look broken.
        HStack(spacing: 12) {
            Text("Style")
                .frame(width: labelColumnWidth, alignment: .trailing)

            Picker("Tint Style", selection: Binding(
                get: { model.solidTint },
                set: { model.setSolidTint($0) }
            )) {
                Text("Gradient").tag(false)
                Text("Solid").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Color selection sits in the value column, aligned under the percentages.
            ColorPicker("Tint Color", selection: Binding(
                get: { model.tintColor },
                set: { model.setTintColor($0) }
            ), supportsOpacity: false)
            .labelsHidden()
            .fixedSize()
            .frame(width: valueColumnWidth, alignment: .trailing)
            .accessibilityLabel("Tint color")
        }
        .font(.body)
    }

    private var tintRow: some View {
        let isOff = model.tintStrengthPercent < 0.5

        return HStack(spacing: 12) {
            // Matches the other slider labels; dims only when Off so it doesn't read
            // as permanently disabled at a live value.
            Text("Strength")
                .foregroundStyle(isOff ? .secondary : .primary)
                .frame(width: labelColumnWidth, alignment: .trailing)

            FillSlider(
                value: Binding(
                    get: { model.tintStrengthPercent },
                    set: { model.setTintStrength($0) }
                ),
                range: 0...100,
                accessibilityLabel: "Tint strength",
                accessibilityValue: isOff ? "Off" : "\(Int(round(model.tintStrengthPercent))) percent"
            )

            Text(isOff ? "Off" : "\(Int(round(model.tintStrengthPercent)))%")
                .monospacedDigit()
                .frame(width: valueColumnWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .font(.body)
    }

    private func sliderRow(
        title: String,
        accessibilityLabel: String? = nil,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        displayValue: String,
        fillFrom: Double? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: labelColumnWidth, alignment: .trailing)

            FillSlider(
                value: value,
                range: range,
                fillFrom: fillFrom,
                accessibilityLabel: accessibilityLabel ?? title,
                accessibilityValue: displayValue
            )

            Text(displayValue)
                .monospacedDigit()
                .frame(width: valueColumnWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .font(.body)
    }
}

/// A slider whose filled portion grows from an arbitrary origin. Unipolar controls fill
/// from the range's start; a bipolar control (e.g. Saturation) fills from its center by
/// passing `fillFrom: 0`, so the neutral value reads as empty instead of half-full.
private struct FillSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var fillFrom: Double? = nil
    let accessibilityLabel: String
    let accessibilityValue: String

    private let thumbSize: CGFloat = 18
    private let trackHeight: CGFloat = 4
    private let hitHeight: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let usable = max(1, width - thumbSize)
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let origin = min(max(fillFrom ?? range.lowerBound, range.lowerBound), range.upperBound)

            let valueX = thumbSize / 2 + usable * ((value - range.lowerBound) / span)
            let originX = thumbSize / 2 + usable * ((origin - range.lowerBound) / span)

            ZStack(alignment: .leading) {
                // Greedy transparent layer: makes the ZStack (and therefore the hit area)
                // fill the full width and height, so the whole thumb — which is taller
                // than the track and positioned with `.offset` — is clickable.
                Color.clear

                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: usable, height: trackHeight)
                    .offset(x: thumbSize / 2)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: abs(valueX - originX), height: trackHeight)
                    .offset(x: min(valueX, originX))

                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: valueX - thumbSize / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let clampedX = min(max(gesture.location.x, thumbSize / 2), width - thumbSize / 2)
                        value = range.lowerBound + (clampedX - thumbSize / 2) / usable * span
                    }
            )
        }
        .frame(height: hitHeight)
        .accessibilityRepresentation {
            Slider(value: $value, in: range) {
                Text(accessibilityLabel)
            }
            .accessibilityValue(accessibilityValue)
        }
    }
}
