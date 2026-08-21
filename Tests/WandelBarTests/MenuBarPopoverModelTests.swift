import Foundation
import Testing
import UniformTypeIdentifiers
@testable import WandelBar

@MainActor
private final class FakeWallpaperEffectController: WallpaperEffectControlling {
    var isEnabled = true
    var state: WandelBarState = .active(since: nil)
    var canCustomizeCurrentSpace = true
    var isCurrentSpaceCustomized = false
    var isCurrentSpaceEffectEnabled = true
    var dontApplyOnLockScreen = false
    var globalSettings = WallpaperEffectSettings.default
    var spaceSettings = WallpaperEffectSettings.default
    var lastUpdatedScope: EffectScope?
    var lastAppliedDelay: TimeInterval?
    var lastSpaceEffectEnabled: Bool?
    var refreshWallpaperSupportCallCount = 0
    var previewContext: PresetPreviewContext?
    var presetPreviewMenuBarHeight: CGFloat = 24
    var onPresetPreviewContextRequested: (() -> Void)?
    var suspendsPresetPreviewContext = false
    private var presetPreviewContextContinuation: CheckedContinuation<Void, Never>?

    var isPresetPreviewContextSuspended: Bool {
        presetPreviewContextContinuation != nil
    }

    func refreshWallpaperSupport() {
        refreshWallpaperSupportCallCount += 1
    }

    func effectSettings(for scope: EffectScope) -> WallpaperEffectSettings {
        scope == .global ? globalSettings : spaceSettings
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func updateEffectSettings(_ settings: WallpaperEffectSettings, for scope: EffectScope) {
        lastUpdatedScope = scope
        if scope == .global {
            globalSettings = settings
        } else {
            spaceSettings = settings
            isCurrentSpaceCustomized = true
        }
    }

    func applySettingsChange(delay: TimeInterval) {
        lastAppliedDelay = delay
    }

    func clearCurrentSpaceOverride() {
        isCurrentSpaceCustomized = false
        isCurrentSpaceEffectEnabled = true
        spaceSettings = globalSettings
    }

    func setCurrentSpaceEffectEnabled(_ enabled: Bool) {
        isCurrentSpaceEffectEnabled = enabled
        lastSpaceEffectEnabled = enabled
        if !enabled {
            isCurrentSpaceCustomized = true
        }
    }

    func setDontApplyOnLockScreen(_ enabled: Bool) {
        dontApplyOnLockScreen = enabled
    }

    func presetPreviewContext() async -> PresetPreviewContext? {
        onPresetPreviewContextRequested?()
        if suspendsPresetPreviewContext {
            await withCheckedContinuation { continuation in
                presetPreviewContextContinuation = continuation
            }
        }
        return previewContext
    }

    func resumePresetPreviewContext() {
        presetPreviewContextContinuation?.resume()
        presetPreviewContextContinuation = nil
    }
}

@MainActor
private final class FakePresetPackageService: PresetPackageServicing {
    var exportResult = PresetPackageExportSummary(presetCount: 1, textureCount: 0)
    var exportedIDs: Set<String> = []
    var preview: PresetPackageImportPreview?
    var importResult = PresetPackageImportResult(presetCount: 1, newTextureCount: 0)
    var discardedIDs: [UUID] = []

    func export(presetIDs: [String], to destinationURL: URL) async throws -> PresetPackageExportSummary {
        exportedIDs = Set(presetIDs)
        return exportResult
    }

    func prepareImport(from packageURL: URL) async throws -> PresetPackageImportPreview {
        guard let preview else { throw PresetPackageError.malformedPackage }
        return preview
    }

    func discardImport(_ preview: PresetPackageImportPreview) {
        discardedIDs.append(preview.id)
    }

    func commitImport(_ preview: PresetPackageImportPreview) throws -> PresetPackageImportResult {
        importResult
    }
}

@Test @MainActor func lockScreenPreferenceLoadsAndUpdatesThroughController() {
    let controller = FakeWallpaperEffectController()
    controller.dontApplyOnLockScreen = true
    let model = MenuBarPopoverModel(controller: controller)

    #expect(model.dontApplyOnLockScreen)

    model.setDontApplyOnLockScreen(false)

    #expect(!model.dontApplyOnLockScreen)
    #expect(!controller.dontApplyOnLockScreen)
}

@Test @MainActor func unavailableWallpaperUsesSamplePresetPreviews() async {
    let suiteName = "WandelBarTests.MenuModel.PresetPreviewFallback.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let model = MenuBarPopoverModel(
        controller: FakeWallpaperEffectController(),
        presetStore: store
    )

    await model.preparePresetPreviews()

    #expect(model.isUsingPresetPreviewFallback)
    #expect(Set(model.presetPreviews.keys) == Set(EffectPreset.builtIns.map(\.id)))
}

@Test @MainActor func presetPlaceholderExistsBeforePreviewPreparationStarts() {
    let model = MenuBarPopoverModel(controller: FakeWallpaperEffectController())

    #expect(model.presetPreviewPlaceholder != nil)
    #expect(model.presetPreviews.isEmpty)
}

@Test @MainActor func catalogPresentationFinishesWallpaperPreparationBeforeItReturns() async {
    let suiteName = "WandelBarTests.MenuModel.CatalogPresentation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let controller = FakeWallpaperEffectController()
    var wallpaperRequestCount = 0
    controller.onPresetPreviewContextRequested = {
        wallpaperRequestCount += 1
    }
    let model = MenuBarPopoverModel(controller: controller, presetStore: store)

    await model.preparePresetCatalogForPresentation()

    #expect(Set(model.presetPreviews.keys) == Set(EffectPreset.builtIns.map(\.id)))
    #expect(wallpaperRequestCount == 1)
    #expect(model.isUsingPresetPreviewFallback)
}

@Test @MainActor func concurrentPreviewPreparationWaitsForTheInFlightWork() async {
    let suiteName = "WandelBarTests.MenuModel.ConcurrentPreviewPreparation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let controller = FakeWallpaperEffectController()
    controller.suspendsPresetPreviewContext = true
    let model = MenuBarPopoverModel(controller: controller, presetStore: store)

    let firstPreparation = Task { @MainActor in
        await model.preparePresetPreviews()
    }
    while !controller.isPresetPreviewContextSuspended {
        await Task.yield()
    }

    var secondPreparationStarted = false
    var secondPreparationReturned = false
    let secondPreparation = Task { @MainActor in
        secondPreparationStarted = true
        await model.preparePresetPreviews()
        secondPreparationReturned = true
    }
    while !secondPreparationStarted {
        await Task.yield()
    }
    await Task.yield()

    #expect(!secondPreparationReturned)

    controller.resumePresetPreviewContext()
    await firstPreparation.value
    await secondPreparation.value
    #expect(secondPreparationReturned)
}

@Test @MainActor func samplePresetTreatmentsAreReadyBeforeWallpaperAccessIsRequested() async {
    let suiteName = "WandelBarTests.MenuModel.PreviewOrder.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller, presetStore: store)
    var previewCountWhenWallpaperWasRequested = -1
    controller.onPresetPreviewContextRequested = {
        previewCountWhenWallpaperWasRequested = model.presetPreviews.count
    }

    await model.preparePresetPreviews()

    #expect(previewCountWhenWallpaperWasRequested == EffectPreset.builtIns.count)
}

@Test @MainActor func samplePresetTreatmentsFollowCurrentDisplayMenuBarHeight() async {
    let suiteName = "WandelBarTests.MenuModel.PreviewMenuBarHeight.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller, presetStore: store)

    controller.presetPreviewMenuBarHeight = 24
    await model.preparePresetPreviews()
    let standardPreview = model.presetPreviews[EffectPreset.BuiltInID.blackBar]?.tiffRepresentation

    controller.presetPreviewMenuBarHeight = 38
    await model.preparePresetPreviews()
    let tallPreview = model.presetPreviews[EffectPreset.BuiltInID.blackBar]?.tiffRepresentation

    #expect(standardPreview != nil)
    #expect(tallPreview != nil)
    #expect(standardPreview != tallPreview)
}

@Test @MainActor func unreadableWallpaperFallsBackToSamplePresetPreviews() async {
    let suiteName = "WandelBarTests.MenuModel.UnreadablePresetPreview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let controller = FakeWallpaperEffectController()
    let missingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("missing-wallpaper.png")
    let display = DisplaySnapshot(
        id: "missing-preview-source",
        localizedName: "Missing Preview Source",
        frame: CGRect(x: 0, y: 0, width: 320, height: 200),
        backingScaleFactor: 1,
        statusBarThickness: 24
    )
    controller.previewContext = PresetPreviewContext(
        sourceURL: missingURL,
        display: display,
        storedDesktop: StoredDesktop(
            urlString: missingURL.absoluteString,
            imageScaling: nil,
            allowClipping: nil,
            fillColorData: nil,
            sourceIdentity: "missing",
            generatedPath: nil
        ),
        sourceIdentity: "missing"
    )
    let model = MenuBarPopoverModel(controller: controller, presetStore: store)

    await model.preparePresetPreviews()

    #expect(model.isUsingPresetPreviewFallback)
    #expect(Set(model.presetPreviews.keys) == Set(EffectPreset.builtIns.map(\.id)))
}

@Test @MainActor func exportDefaultsToActiveUserPresetOtherwiseAllUsers() throws {
    let suiteName = "WandelBarTests.MenuModel.Export.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let one = try store.createUserPreset(name: "One", settings: .default)
    let two = try store.createUserPreset(name: "Two", settings: .default)
    let model = MenuBarPopoverModel(
        controller: FakeWallpaperEffectController(),
        presetStore: store,
        presetPackageService: FakePresetPackageService()
    )

    model.applyPreset(id: one.id)
    model.beginPresetExportSelection()
    #expect(model.exportPresetIDs == [one.id])

    model.applyPreset(id: EffectPreset.BuiltInID.default)
    model.beginPresetExportSelection()
    #expect(model.exportPresetIDs == Set([one.id, two.id]))
}

@Test @MainActor func packageWorkflowReportsSummariesWithoutApplyingImportedPreset() async throws {
    let service = FakePresetPackageService()
    service.exportResult = PresetPackageExportSummary(presetCount: 2, textureCount: 1)
    let token = PresetPackageImportToken()
    service.preview = PresetPackageImportPreview(
        presets: [.init(
            id: "source", sourceName: "Ocean", finalName: "Ocean", wasRenamed: false
        )],
        embeddedTextureCount: 1,
        token: token
    )
    service.importResult = PresetPackageImportResult(presetCount: 1, newTextureCount: 1)
    let controller = FakeWallpaperEffectController()
    let before = controller.globalSettings
    let model = MenuBarPopoverModel(
        controller: controller,
        presetPackageService: service
    )
    model.exportPresetIDs = ["one", "two"]

    await model.exportSelectedPresets(to: URL(fileURLWithPath: "/tmp/share.wandelbar-presets"))
    #expect(model.presetPackageCompletion == "Exported 2 presets and 1 texture.")
    await model.preparePresetImport(from: URL(fileURLWithPath: "/tmp/share.wandelbar-presets"))
    #expect(model.importPreview?.presets.map(\.finalName) == ["Ocean"])
    model.commitPresetImport()
    #expect(model.presetPackageCompletion == "Imported 1 preset and 1 new texture.")
    #expect(controller.globalSettings == before)
}

@Test @MainActor func quitWithActiveLockScreenProtectionRequestsConfirmation() {
    let controller = FakeWallpaperEffectController()
    controller.isEnabled = true
    controller.dontApplyOnLockScreen = true
    var terminationCount = 0
    let model = MenuBarPopoverModel(
        controller: controller,
        terminateApplication: { terminationCount += 1 }
    )

    model.requestQuit()

    #expect(model.isQuitConfirmationPresented)
    #expect(terminationCount == 0)
}

@Test @MainActor func quitWhileWandelBarIsOffTerminatesWithoutConfirmation() {
    let controller = FakeWallpaperEffectController()
    controller.isEnabled = false
    controller.dontApplyOnLockScreen = true
    var terminationCount = 0
    let model = MenuBarPopoverModel(
        controller: controller,
        terminateApplication: { terminationCount += 1 }
    )

    model.requestQuit()

    #expect(!model.isQuitConfirmationPresented)
    #expect(terminationCount == 1)
}

@Test @MainActor func quitWhileWandelBarIsEnabledRequestsConfirmation() {
    let controller = FakeWallpaperEffectController()
    controller.isEnabled = true
    controller.dontApplyOnLockScreen = false
    var terminationCount = 0
    let model = MenuBarPopoverModel(
        controller: controller,
        terminateApplication: { terminationCount += 1 }
    )

    model.requestQuit()

    #expect(model.isQuitConfirmationPresented)
    #expect(terminationCount == 0)
}

@Test @MainActor func turnOffAndQuitDisablesWandelBarBeforeTermination() {
    let controller = FakeWallpaperEffectController()
    controller.isEnabled = true
    controller.dontApplyOnLockScreen = true
    var wasEnabledWhenTerminated: Bool?
    let model = MenuBarPopoverModel(
        controller: controller,
        terminateApplication: { wasEnabledWhenTerminated = controller.isEnabled }
    )
    model.requestQuit()

    model.turnOffAndQuit()

    #expect(wasEnabledWhenTerminated == false)
    #expect(!model.isQuitConfirmationPresented)
}

@Test @MainActor func keepBarAndQuitLeavesWandelBarEnabled() {
    let controller = FakeWallpaperEffectController()
    controller.isEnabled = true
    controller.dontApplyOnLockScreen = true
    var wasEnabledWhenTerminated: Bool?
    let model = MenuBarPopoverModel(
        controller: controller,
        terminateApplication: { wasEnabledWhenTerminated = controller.isEnabled }
    )
    model.requestQuit()

    model.keepBarAndQuit()

    #expect(wasEnabledWhenTerminated == true)
    #expect(!model.isQuitConfirmationPresented)
}

@Test @MainActor func cancellingQuitDismissesConfirmationWithoutTermination() {
    let controller = FakeWallpaperEffectController()
    controller.isEnabled = true
    controller.dontApplyOnLockScreen = true
    var terminationCount = 0
    let model = MenuBarPopoverModel(
        controller: controller,
        terminateApplication: { terminationCount += 1 }
    )
    model.requestQuit()

    model.cancelQuit()

    #expect(!model.isQuitConfirmationPresented)
    #expect(terminationCount == 0)
    #expect(controller.isEnabled)
}

@Test @MainActor func applyingPresetTargetsSelectedSpaceAndRefreshesImmediately() {
    let suiteName = "WandelBarTests.MenuModel.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller, presetStore: store)

    model.setScope(.currentSpace)
    model.applyPreset(id: EffectPreset.BuiltInID.dark)

    #expect(controller.lastUpdatedScope == .currentSpace)
    #expect(controller.spaceSettings == store.preset(id: EffectPreset.BuiltInID.dark)?.settings)
    #expect(controller.lastAppliedDelay == 0)
    #expect(model.activePreset?.id == EffectPreset.BuiltInID.dark)
}

@Test @MainActor func disablingCurrentSpaceKeepsItsSettingsAndDisablesOnlyItsEditor() {
    let controller = FakeWallpaperEffectController()
    var custom = WallpaperEffectSettings.default
    custom.blurRadiusPoints = 9
    controller.spaceSettings = custom
    controller.isCurrentSpaceCustomized = true
    let model = MenuBarPopoverModel(controller: controller)
    model.setScope(.currentSpace)

    model.setCurrentSpaceEffectEnabled(false)

    #expect(controller.lastSpaceEffectEnabled == false)
    #expect(controller.spaceSettings == custom)
    #expect(!model.isCurrentSpaceEffectEnabled)
    #expect(!model.isEffectEditorEnabled)
    #expect(model.isSpaceCustomized)
    #expect(model.isSpaceDifferentFromDefault)
}

@Test @MainActor func reenablingCurrentSpaceRestoresItsEditorWithoutChangingSettings() {
    let controller = FakeWallpaperEffectController()
    var custom = WallpaperEffectSettings.default
    custom.blurLengthPoints = 88
    controller.spaceSettings = custom
    controller.isCurrentSpaceCustomized = true
    controller.isCurrentSpaceEffectEnabled = false
    let model = MenuBarPopoverModel(controller: controller)
    model.setScope(.currentSpace)

    model.setCurrentSpaceEffectEnabled(true)

    #expect(controller.lastSpaceEffectEnabled == true)
    #expect(controller.spaceSettings == custom)
    #expect(model.isCurrentSpaceEffectEnabled)
    #expect(model.isEffectEditorEnabled)
}

@Test @MainActor func matchingDefaultKeepsSpaceOverrideButHidesDifferenceIndicator() {
    let controller = FakeWallpaperEffectController()
    let spacePreset = EffectPreset.builtIns.first {
        $0.id == EffectPreset.BuiltInID.dark
    }!
    controller.spaceSettings = spacePreset.settings
    controller.isCurrentSpaceCustomized = true
    let model = MenuBarPopoverModel(controller: controller)

    model.applyPreset(id: spacePreset.id)

    #expect(model.isSpaceCustomized)
    #expect(controller.isCurrentSpaceCustomized)
    #expect(!model.isSpaceDifferentFromDefault)
}

@Test @MainActor func laterDefaultChangeRevealsPreservedSpaceDifference() {
    let controller = FakeWallpaperEffectController()
    let spacePreset = EffectPreset.builtIns.first {
        $0.id == EffectPreset.BuiltInID.dark
    }!
    controller.globalSettings = spacePreset.settings
    controller.spaceSettings = spacePreset.settings
    controller.isCurrentSpaceCustomized = true
    let model = MenuBarPopoverModel(controller: controller)
    #expect(!model.isSpaceDifferentFromDefault)

    model.applyPreset(id: EffectPreset.BuiltInID.default)

    #expect(model.isSpaceCustomized)
    #expect(model.isSpaceDifferentFromDefault)
    #expect(controller.spaceSettings == spacePreset.settings)
}

@Test @MainActor func manualEditChangesMatchingPresetToCustom() {
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller)

    #expect(model.activePreset?.id == EffectPreset.BuiltInID.default)
    model.setBlurRadius(13)
    #expect(model.activePreset == nil)
}

@Test @MainActor func shadowControlsLoadAndUpdateCurrentScope() {
    let controller = FakeWallpaperEffectController()
    controller.spaceSettings.shadowStrength = 0.60
    controller.spaceSettings.shadowLengthPoints = 12
    let model = MenuBarPopoverModel(controller: controller)
    model.setScope(.currentSpace)

    #expect(model.shadowStrengthPercent == 60)
    #expect(model.shadowLength == 12)

    model.setShadowStrength(25)
    #expect(controller.lastUpdatedScope == .currentSpace)
    #expect(controller.spaceSettings.shadowStrength == 0.25)
    #expect(controller.lastAppliedDelay == 0.3)

    model.setShadowLength(20)
    #expect(controller.lastUpdatedScope == .currentSpace)
    #expect(controller.spaceSettings.shadowLengthPoints == 20)
    #expect(controller.lastAppliedDelay == 0.3)
}

@Test @MainActor func userPresetManagementKeepsAppliedSettingsAsSnapshots() throws {
    let suiteName = "WandelBarTests.MenuModel.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let controller = FakeWallpaperEffectController()
    controller.globalSettings = EffectPreset.builtIns[1].settings
    let model = MenuBarPopoverModel(controller: controller, presetStore: store)

    model.setBlurRadius(7)
    let saved = try model.saveCurrentPreset(name: "My Look")
    #expect(model.activeUserPreset?.id == saved.id)

    try model.renameActivePreset(to: "Renamed")
    #expect(model.activeUserPreset?.name == "Renamed")
    let appliedSettings = controller.globalSettings

    try model.deleteActivePreset()
    #expect(controller.globalSettings == appliedSettings)
    #expect(model.activePreset == nil)
}

@Test @MainActor func savedPresetCanBeManagedWhenItsSettingsMatchABuiltIn() throws {
    let suiteName = "WandelBarTests.MenuModel.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let model = MenuBarPopoverModel(
        controller: FakeWallpaperEffectController(),
        presetStore: store
    )

    let saved = try model.saveCurrentPreset(name: "My Default")

    #expect(model.activeUserPreset?.id == saved.id)
    try model.renameActivePreset(to: "Personal Default")
    #expect(model.activeUserPreset?.name == "Personal Default")
}

@Test @MainActor func replacingPresetFromCatalogUsesCurrentSettingsAndSelectsIt() throws {
    let suiteName = "WandelBarTests.MenuModel.ReplacePreset.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller, presetStore: store)
    let original = try model.saveCurrentPreset(name: "Night")
    let replacementSettings = EffectPreset.builtIns[1].settings
    controller.globalSettings = replacementSettings
    model.reloadFromController()

    let replaced = try model.replacePreset(id: original.id)

    #expect(replaced.id == original.id)
    #expect(replaced.settings == replacementSettings)
    #expect(model.activePreset?.id == original.id)
    #expect(model.userPresets.count == 1)
}

@Test @MainActor func savingPresetPublishesItWithAPreparedPreview() async throws {
    let suiteName = "WandelBarTests.MenuModel.SaveWithoutPreviewFlash.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let model = MenuBarPopoverModel(
        controller: FakeWallpaperEffectController(),
        presetStore: store
    )

    let saved = try await model.saveCurrentPresetWithPreparedPreview(name: "No Flash")

    #expect(model.presetPreviews[saved.id] != nil)
}

@Test @MainActor func catalogActionsCanRenameAndDeleteANonActivePreset() throws {
    let suiteName = "WandelBarTests.MenuModel.CardActions.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let model = MenuBarPopoverModel(
        controller: FakeWallpaperEffectController(),
        presetStore: store
    )
    let first = try model.saveCurrentPreset(name: "First")
    _ = try model.saveCurrentPreset(name: "Second")

    try model.renamePreset(id: first.id, to: "Renamed")
    #expect(model.userPresets.map(\.name) == ["Renamed", "Second"])

    try model.deletePreset(id: first.id)
    #expect(model.userPresets.map(\.name) == ["Second"])
}

@Test @MainActor func frostedPresetSurvivesTheSwiftUIColorRoundTrip() {
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller)

    model.applyPreset(id: EffectPreset.BuiltInID.frosted)

    #expect(model.activePreset?.id == EffectPreset.BuiltInID.frosted)
    #expect(model.activePresetName == "Frosted")
}

@Test @MainActor func everyBuiltInPresetRemainsSelectedAfterApplication() {
    let model = MenuBarPopoverModel(controller: FakeWallpaperEffectController())

    for preset in EffectPreset.builtIns {
        model.applyPreset(id: preset.id)
        #expect(model.activePreset?.id == preset.id, "\(preset.name) became Custom")
    }
}

@Test @MainActor func selectingTextureTargetsCurrentScopeWithVisibleDefaults() throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(
        controller: controller,
        textureStore: fixture.store
    )
    model.setScope(.currentSpace)

    model.selectTexture(id: TextureAsset.azureReflection.id)

    #expect(controller.lastUpdatedScope == .currentSpace)
    #expect(controller.spaceSettings.textureID == TextureAsset.azureReflection.id)
    #expect(controller.spaceSettings.textureBlendMode == .screen)
    #expect(controller.spaceSettings.textureStrength == 0.45)
    #expect(controller.lastAppliedDelay == 0)
}

@Test @MainActor func switchingTexturePreservesActiveControlsAndNoneNormalizes() throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller, textureStore: fixture.store)
    model.selectTexture(id: TextureAsset.azureReflection.id)
    model.setTextureBlendMode(.softLight)
    model.setTextureStrength(68)

    model.selectTexture(id: "custom.another")
    #expect(controller.globalSettings.textureID == "custom.another")
    #expect(controller.globalSettings.textureBlendMode == .softLight)
    #expect(controller.globalSettings.textureStrength == 0.68)

    model.selectTexture(id: nil)
    #expect(controller.globalSettings.textureID == nil)
    #expect(controller.globalSettings.textureBlendMode == .screen)
    #expect(controller.globalSettings.textureStrength == 0)
    #expect(controller.lastAppliedDelay == 0)
}

@Test @MainActor func textureMenuProjectionShowsAllBuiltInsAndHidesInactiveImports() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let source = try fixture.makeImage(
        name: "historical-texture",
        type: .png,
        width: 20,
        height: 12
    )
    let historical = try await fixture.store.importTexture(from: source)
    let model = MenuBarPopoverModel(
        controller: FakeWallpaperEffectController(),
        textureStore: fixture.store
    )

    #expect(model.builtInPresetSections == EffectPreset.builtInSections)
    #expect(model.builtInTextures == TextureAsset.builtIns)
    #expect(model.selectedCustomTexture == nil)

    model.selectTexture(id: historical.id)
    #expect(model.selectedCustomTexture == historical)

    model.selectTexture(id: TextureAsset.stripedLight.id)
    #expect(model.selectedCustomTexture == nil)

    model.selectTexture(id: historical.id)
    model.selectTexture(id: nil)
    #expect(model.selectedCustomTexture == nil)
}

@Test @MainActor func textureLayoutControlsTargetTheCurrentScope() throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller, textureStore: fixture.store)
    model.selectTexture(id: TextureAsset.azureReflection.id)

    model.setTextureLayoutMode(.fillBand)
    model.setTextureVerticalPosition(65)

    #expect(controller.globalSettings.textureLayoutMode == .fillBand)
    #expect(controller.globalSettings.textureVerticalPosition == 0.65)
    #expect(controller.lastAppliedDelay == 0.3)
}

@Test @MainActor func textureControlDelaysMatchInteractionType() throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller, textureStore: fixture.store)
    model.selectTexture(id: TextureAsset.azureReflection.id)

    model.setTextureBlendMode(.overlay)
    #expect(controller.globalSettings.textureBlendMode == .overlay)
    #expect(controller.lastAppliedDelay == 0)

    model.setTextureStrength(73)
    #expect(controller.globalSettings.textureStrength == 0.73)
    #expect(controller.lastAppliedDelay == 0.3)
}

@Test @MainActor func failedTextureImportPreservesSettingsAndExposesError() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller, textureStore: fixture.store)
    let before = controller.globalSettings
    let corrupt = fixture.directory.appendingPathComponent("broken.png")
    try Data("broken".utf8).write(to: corrupt)

    await model.importTexture(from: corrupt)

    #expect(controller.globalSettings == before)
    #expect(model.textureImportError != nil)
}

@Test @MainActor func importedTextureRoundTripsThroughUserPreset() async throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let suiteName = "WandelBarTests.MenuTexturePreset.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let presets = EffectPresetStore(defaults: defaults, storageKey: "presets")
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(
        controller: controller,
        presetStore: presets,
        textureStore: fixture.store
    )
    let source = try fixture.makeImage(
        name: "popover-import",
        type: .png,
        width: 20,
        height: 12
    )

    await model.importTexture(from: source)
    model.setTextureBlendMode(.overlay)
    model.setTextureStrength(62)
    let saved = try model.saveCurrentPreset(name: "Imported Glass")
    model.selectTexture(id: nil)
    model.applyPreset(id: saved.id)

    #expect(controller.globalSettings.textureID == saved.settings.textureID)
    #expect(controller.globalSettings.textureBlendMode == .overlay)
    #expect(controller.globalSettings.textureStrength == 0.62)
    #expect(model.selectedCustomTexture?.id == saved.settings.textureID)
}

@Test @MainActor func unavailableSelectedTextureIsReportedWithoutChangingItsID() throws {
    let fixture = try TextureStoreFixture()
    defer { fixture.cleanUp() }
    let controller = FakeWallpaperEffectController()
    var missing = WallpaperEffectSettings.default
    missing.textureID = "custom.missing"
    missing.textureStrength = 0.5
    controller.globalSettings = missing

    let model = MenuBarPopoverModel(controller: controller, textureStore: fixture.store)

    #expect(model.selectedTextureName == "Missing Texture")
    #expect(model.selectedCustomTexture == nil)
    #expect(model.selectedTextureID == "custom.missing")
}

@Test @MainActor func unsupportedWallpaperIsAnoticeRatherThanAnError() {
    let controller = FakeWallpaperEffectController()
    controller.state = .unsupported("video wallpapers are not supported")
    let model = MenuBarPopoverModel(controller: controller)

    #expect(model.errorMessage == nil)
    #expect(model.noticeMessage == "Video wallpapers are not supported")
}

@Test @MainActor func fileDialogsAreDelegatedToThePresenterInsteadOfThePopover() {
    let presenter = RecordingMenuBarDialogPresenter()
    let model = MenuBarPopoverModel(controller: FakeWallpaperEffectController())
    model.dialogPresenter = presenter

    model.requestTextureImport()
    model.requestPresetImport()
    model.requestPresetExport()

    #expect(presenter.calls == ["texture", "import", "export"])
}

@MainActor
private final class RecordingMenuBarDialogPresenter: MenuBarDialogPresenting {
    private(set) var calls: [String] = []

    func presentTextureImport() { calls.append("texture") }
    func presentPresetImport() { calls.append("import") }
    func presentPresetExport() { calls.append("export") }
}

@Test @MainActor func openingThePopoverRechecksWhetherTheWallpaperCanBeTreated() {
    // macOS posts nothing when the wallpaper changes, so the popover has to ask.
    let controller = FakeWallpaperEffectController()
    let model = MenuBarPopoverModel(controller: controller)
    #expect(controller.refreshWallpaperSupportCallCount == 0)

    model.prepareForDisplay()

    #expect(controller.refreshWallpaperSupportCallCount == 1)
}
