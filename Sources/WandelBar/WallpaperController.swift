import AppKit

enum WandelBarState: Equatable {
    case off
    case active(since: Date?)
    /// The current wallpaper is a kind WandelBar deliberately leaves alone, such as a
    /// video wallpaper. Nothing was applied and nothing was damaged.
    case unsupported(String)
    case error(String)
}

/// Which set of settings the popover is editing.
enum EffectScope: Hashable {
    case global
    case currentSpace
}

@MainActor
final class WallpaperController: NSObject {
    var onStateChanged: (() -> Void)?

    nonisolated fileprivate static let unsupportedWallpaperErrorDomain = "WandelBar.UnsupportedWallpaper"

    private enum DefaultsKey {
        static let enabled = "WandelBar.enabled"
        static let storedDesktops = "WandelBar.storedDesktops"
        static let dontApplyOnLockScreen = "WandelBar.dontApplyOnLockScreen"
    }

    private let sourceResolver = WallpaperStoreResolver()
    private let settingsStore = WallpaperEffectSettingsStore.shared
    private let textureStore: TextureAssetStore
    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private var refreshTimer: Timer?
    private var pendingRefresh: DispatchWorkItem?
    private var pendingRestore: DispatchWorkItem?
    private var shouldRestoreOriginalsOnSpaceChange = false
    private var lastError: String?
    private var lastUnsupported: String?
    private var lastSuccessfulApplyDate: Date?
    private var isApplying = false
    private var reapplyRequested = false
    private var isStopping = false
    private var isSessionActive = true
    private var editingDisplayID: String?
    /// Invalidates work captured before the latest settings, display, Space, or lifecycle change.
    private var generationRevision: UInt64 = 0
    private lazy var lockScreenWallpaperCoordinator = LockScreenWallpaperCoordinator(
        isEnabled: { [weak self] in self?.isEnabled ?? false },
        dontApplyOnLockScreen: { [weak self] in self?.dontApplyOnLockScreen ?? false },
        apply: { [weak self] transition in
            self?.applyLockScreenWallpaperTransition(transition)
        }
    )
    private lazy var lockScreenEventMonitor = LockScreenEventMonitor(
        onLock: { [weak self] in self?.lockScreenDidLock() },
        onUnlock: { [weak self] in self?.lockScreenDidUnlock() }
    )

    init(
        textureStore: TextureAssetStore = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.textureStore = textureStore
        self.defaults = defaults
        super.init()
    }

    var isEnabled: Bool {
        defaults.bool(forKey: DefaultsKey.enabled)
    }

    var dontApplyOnLockScreen: Bool {
        defaults.bool(forKey: DefaultsKey.dontApplyOnLockScreen)
    }

    func setDontApplyOnLockScreen(_ enabled: Bool) {
        defaults.set(enabled, forKey: DefaultsKey.dontApplyOnLockScreen)
        if !enabled {
            lockScreenWallpaperCoordinator.unlock()
            if isEnabled, isSessionActive {
                scheduleRefresh(force: true, delay: 0.5)
            }
        }
    }

    /// The active Space of the display the popover is shown on. Edits target this Space.
    var editingSpaceUUID: String? {
        let screen = editingDisplayID.flatMap(screen(forDisplayID:))
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return nil }
        return sourceResolver.activeSpaceUUID(for: DisplaySnapshot(screen: screen))
    }

    func setEditingScreen(_ screen: NSScreen?) {
        editingDisplayID = screen.map { DisplaySnapshot(screen: $0).id }
    }

    /// Whether the current Space can have its own settings (requires a resolvable Space).
    var canCustomizeCurrentSpace: Bool {
        editingSpaceUUID != nil
    }

    /// Whether the current Space currently has its own settings override.
    var isCurrentSpaceCustomized: Bool {
        guard let space = editingSpaceUUID else { return false }
        return settingsStore.override(for: space) != nil
            || !settingsStore.isEffectEnabled(for: space)
    }

    var isCurrentSpaceEffectEnabled: Bool {
        settingsStore.isEffectEnabled(for: editingSpaceUUID)
    }

    /// The settings currently shown for the given editing scope. For `.currentSpace`
    /// before the Space is customized this returns the global values (which the first
    /// edit then forks into a Space-specific override).
    func effectSettings(for scope: EffectScope) -> WallpaperEffectSettings {
        switch scope {
        case .global:
            return settingsStore.global
        case .currentSpace:
            return settingsStore.effectiveSettings(for: editingSpaceUUID)
        }
    }

    /// Writes edited settings to the chosen scope. Editing `.currentSpace` creates the
    /// per-Space override if it does not exist yet.
    func updateEffectSettings(_ settings: WallpaperEffectSettings, for scope: EffectScope) {
        switch scope {
        case .global:
            settingsStore.global = settings
        case .currentSpace:
            if let space = editingSpaceUUID {
                settingsStore.setOverride(settings, for: space)
            } else {
                settingsStore.global = settings
            }
        }
    }

    /// Drops the current Space's override so it reverts to the global settings.
    func clearCurrentSpaceOverride() {
        guard let space = editingSpaceUUID else { return }
        settingsStore.setOverride(nil, for: space)
        settingsStore.setEffectEnabled(true, for: space)
        applySettingsChange(delay: 0)
    }

    func setCurrentSpaceEffectEnabled(_ enabled: Bool) {
        guard let space = editingSpaceUUID,
              settingsStore.isEffectEnabled(for: space) != enabled else { return }

        settingsStore.setEffectEnabled(enabled, for: space)
        if enabled {
            applySettingsChange(delay: 0)
        } else {
            generationRevision &+= 1
            pendingRefresh?.cancel()
            pendingRefresh = nil
            reapplyRequested = false
            restoreOriginals(
                removeRestoredEntries: true,
                onlyGeneratedCurrentWallpapers: true,
                matchingSpace: { $0 == space }
            )
        }
    }

    var state: WandelBarState {
        if let lastError {
            return .error(lastError)
        }

        guard isEnabled else { return .off }

        if let lastUnsupported {
            return .unsupported(lastUnsupported)
        }

        return .active(since: lastSuccessfulApplyDate)
    }

    var statusText: String {
        switch state {
        case .error(let message):
            return "WandelBar: \(message)"
        case .unsupported(let message):
            return "WandelBar: \(message)"
        case .active(let since):
            if let since {
                return "WandelBar: active since \(Self.statusDateFormatter.string(from: since))"
            }
            return "WandelBar: active"
        case .off:
            return "WandelBar: off"
        }
    }

    var generatedDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Generated", isDirectory: true)
    }

    private var applicationSupportDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WandelBar", isDirectory: true)
    }

    private static let statusDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    func start() {
        isStopping = false
        isSessionActive = true
        ensureSupportDirectories()

        // A disabled Space may become visible after launch or a Space switch. Restore
        // its original before excluding it from the render pass.
        restoreOriginals(
            removeRestoredEntries: true,
            onlyGeneratedCurrentWallpapers: true,
            matchingSpace: { [settingsStore] space in
                !settingsStore.isEffectEnabled(for: space)
            },
            notifyWhenFinished: false
        )
        pruneOrphanedGeneratedFiles()
        pruneStaleOriginalCaches()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        lockScreenEventMonitor.start()

        if isEnabled {
            startTimer()
            scheduleRefresh(force: true, delay: 0.5)
        } else if !storedDesktops.isEmpty {
            shouldRestoreOriginalsOnSpaceChange = true
            scheduleRestoreOriginals(delay: 0.5)
        }
    }

    func stop() {
        isStopping = true
        generationRevision &+= 1
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingRestore?.cancel()
        pendingRestore = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        lockScreenEventMonitor.stop()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    func applySettingsChange(delay: TimeInterval) {
        guard isEnabled else { return }
        scheduleRefresh(force: true, delay: delay)
    }


    private func enable() {
        isStopping = false
        generationRevision &+= 1
        pendingRestore?.cancel()
        pendingRestore = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        shouldRestoreOriginalsOnSpaceChange = false
        defaults.set(true, forKey: DefaultsKey.enabled)
        lastError = nil
        lastUnsupported = nil
        startTimer()
        applyBlurredWallpapers(force: true)
        notifyStateChanged()
    }

    private func disable() {
        generationRevision &+= 1
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingRestore?.cancel()
        pendingRestore = nil
        refreshTimer?.invalidate()
        refreshTimer = nil

        shouldRestoreOriginalsOnSpaceChange = true
        defaults.set(false, forKey: DefaultsKey.enabled)
        lockScreenWallpaperCoordinator.unlock()
        restoreOriginals(
            removeRestoredEntries: true,
            onlyGeneratedCurrentWallpapers: false
        )
    }

    private func restoreOriginals(
        removeRestoredEntries: Bool,
        onlyGeneratedCurrentWallpapers: Bool,
        matchingSpace: (String?) -> Bool = { _ in true },
        notifyWhenFinished: Bool = true
    ) {
        var saved = storedDesktops
        var failures: [String] = []

        for screen in NSScreen.screens {
            let display = DisplaySnapshot(screen: screen)
            if sourceResolver.activeSpaceContext(for: display)?.isFullscreen == true {
                continue
            }
            let activeSpaceUUID = sourceResolver.activeSpaceUUID(for: display)
            guard matchingSpace(activeSpaceUUID) else { continue }
            guard let storedEntry = Self.savedDesktopEntry(
                for: display,
                spaceUUID: activeSpaceUUID,
                in: saved
            ) else { continue }
            let stored = storedEntry.desktop

            guard let url = stored.url else {
                if removeRestoredEntries, !currentWallpaperIsGenerated(for: screen) {
                    removeStoredEntry(storedEntry.key, from: &saved)
                } else {
                    failures.append("\(screen.localizedName): stored original URL is invalid")
                }
                continue
            }

            if url.isFileURL, !fileManager.fileExists(atPath: url.path) {
                // Never delete the generated file that is still active merely because its
                // original disappeared. Keep recovery metadata and report the failure. If the
                // user already selected another wallpaper, the stale entry is safe to remove.
                if removeRestoredEntries, !currentWallpaperIsGenerated(for: screen) {
                    removeStoredEntry(storedEntry.key, from: &saved)
                } else {
                    failures.append("\(screen.localizedName): original wallpaper no longer exists")
                }
                continue
            }

            if WallpaperRestorePolicy.shouldAbandonStoredOriginal(
                currentIsGenerated: currentWallpaperIsGenerated(for: screen),
                unsupportedReason: unsupportedWallpaperReason(for: screen)
            ) {
                if removeRestoredEntries {
                    removeStoredEntry(storedEntry.key, from: &saved)
                }
                continue
            }

            if onlyGeneratedCurrentWallpapers,
               !currentWallpaperIsGenerated(for: screen) {
                continue
            }

            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: stored.workspaceOptions)

                if removeRestoredEntries {
                    removeStoredEntry(storedEntry.key, from: &saved)
                }
            } catch {
                failures.append(screen.localizedName)
            }
        }

        if removeRestoredEntries {
            storedDesktops = saved
            shouldRestoreOriginalsOnSpaceChange = !saved.isEmpty
        }

        if failures.isEmpty {
            lastError = nil
        } else {
            lastError = "restore failed on \(failures.joined(separator: ", "))"
        }

        if notifyWhenFinished {
            notifyStateChanged()
        }
    }

    /// Re-reads only the wallpaper store to answer "can WandelBar treat what is on screen
    /// right now". macOS posts no notification when the wallpaper changes, so without this
    /// the popover could show "On" for minutes after the user switched to a video wallpaper.
    func refreshWallpaperSupport() {
        guard isEnabled, !isStopping, isSessionActive else { return }

        var reason: String?
        for screen in NSScreen.screens {
            let display = DisplaySnapshot(screen: screen)
            if sourceResolver.activeSpaceContext(for: display)?.isFullscreen == true {
                continue
            }

            let activeSpaceUUID = sourceResolver.activeSpaceUUID(for: display)
            guard settingsStore.isEffectEnabled(for: activeSpaceUUID) else { continue }

            if let found = unsupportedWallpaperReason(for: screen) {
                reason = found
                break
            }
        }

        guard reason != lastUnsupported else { return }

        lastUnsupported = reason
        notifyStateChanged()

        // Coming back from a video wallpaper: apply immediately instead of waiting for
        // the next poll.
        if reason == nil {
            scheduleRefresh(force: true, delay: 0)
        }
    }

    /// Store-only check for one screen, safe to call from the main actor.
    private func unsupportedWallpaperReason(for screen: NSScreen) -> String? {
        let display = DisplaySnapshot(screen: screen)
        if let reason = sourceResolver.unsupportedReason(for: display) {
            return reason
        }

        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           WallpaperStoreResolver.isDynamicWallpaperPlaceholder(url) {
            return WallpaperStoreResolver.videoWallpaperReason
        }

        return nil
    }

    private func applyBlurredWallpapers(force: Bool) {
        guard isEnabled,
              !isStopping,
              isSessionActive,
              !lockScreenWallpaperCoordinator.isPresentingOriginal else { return }

        ensureSupportDirectories()

        restoreOriginals(
            removeRestoredEntries: true,
            onlyGeneratedCurrentWallpapers: true,
            matchingSpace: { [settingsStore] space in
                !settingsStore.isEffectEnabled(for: space)
            },
            notifyWhenFinished: false
        )

        if !force && !shouldRefreshGeneratedWallpapers() {
            // Nothing to re-render, but the wallpaper may have become one WandelBar
            // refuses to touch since the last pass.
            refreshWallpaperSupport()
            return
        }

        if isApplying {
            // Coalesce overlapping requests into a single follow-up pass.
            reapplyRequested = true
            return
        }

        isApplying = true

        let saved = storedDesktops
        let generatedDirectory = self.generatedDirectory
        let inputs = NSScreen.screens.compactMap { screen -> ScreenInput? in
            let display = DisplaySnapshot(screen: screen)
            let spaceContext = sourceResolver.activeSpaceContext(for: display)
            // NSWorkspace cannot target a fullscreen Space. Applying while one is active
            // mutates an ordinary desktop behind it and changes the lock-screen wallpaper.
            guard spaceContext?.isFullscreen != true else { return nil }

            let spaceUUID = spaceContext?.activeSpaceUUID
            guard let settings = settingsStore.enabledSettings(for: spaceUUID) else {
                return nil
            }
            return ScreenInput(
                display: display,
                spaceUUID: spaceUUID,
                workspaceURL: NSWorkspace.shared.desktopImageURL(for: screen),
                options: DesktopOptionsSnapshot(
                    options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
                ),
                settings: settings,
                textureURL: textureStore.resolvedURL(for: settings.textureID)
            )
        }
        let revision = generationRevision

        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.generate(
                    inputs: inputs,
                    saved: saved,
                    generatedDirectory: generatedDirectory
                )
            }.value

            self?.finishApply(outcome: outcome, revision: revision)
        }
    }

    var presetPreviewMenuBarHeight: CGFloat {
        guard let screen = presetPreviewScreen else { return 24 }
        return DisplaySnapshot(screen: screen).menuBarHeightPoints
    }

    func presetPreviewContext() async -> PresetPreviewContext? {
        guard let screen = presetPreviewScreen else { return nil }

        let display = DisplaySnapshot(screen: screen)
        let spaceContext = sourceResolver.activeSpaceContext(for: display)
        guard spaceContext?.isFullscreen != true else { return nil }
        let input = ScreenInput(
            display: display,
            spaceUUID: spaceContext?.activeSpaceUUID,
            workspaceURL: NSWorkspace.shared.desktopImageURL(for: screen),
            options: DesktopOptionsSnapshot(
                options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            ),
            settings: .default,
            textureURL: nil
        )
        let saved = storedDesktops
        let previewGeneratedDirectory = generatedDirectory

        return await Task.detached(priority: .userInitiated) {
            switch Self.preparedWallpaperSource(
                for: input,
                saved: saved,
                resolver: WallpaperStoreResolver(),
                generatedDirectory: previewGeneratedDirectory
            ) {
            case .success(let prepared):
                return PresetPreviewContext(
                    sourceURL: prepared.renderSource.renderURL,
                    display: display,
                    storedDesktop: prepared.storedDesktop,
                    sourceIdentity: prepared.sourceIdentity.stableIdentifier
                )
            case .failure:
                return nil
            }
        }.value
    }

    private var presetPreviewScreen: NSScreen? {
        editingDisplayID.flatMap(screen(forDisplayID:))
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func finishApply(outcome: GenerationOutcome, revision: UInt64) {
        guard isEnabled,
              !isStopping,
              isSessionActive,
              !lockScreenWallpaperCoordinator.isPresentingOriginal else {
            // WandelBar was turned off or the app began terminating while this pass was
            // rendering; discard it so termination never commits a half-finished update.
            discardGeneratedFiles(in: outcome)
            isApplying = false
            reapplyRequested = false
            return
        }

        guard revision == generationRevision else {
            discardGeneratedFiles(in: outcome)
            isApplying = false
            reapplyRequested = false
            scheduleRefresh(force: true, delay: 0)
            return
        }

        var saved = storedDesktops
        var failures = outcome.failures
        var skippedStaleResult = false

        for result in outcome.results {
            guard let screen = screen(forDisplayID: result.display.id) else {
                // The display disappeared while rendering; a later pass will retry.
                try? fileManager.removeItem(at: result.outputURL)
                skippedStaleResult = true
                continue
            }

            let currentDisplay = DisplaySnapshot(screen: screen)
            let currentSpaceUUID = sourceResolver.activeSpaceUUID(for: currentDisplay)
            let currentStoreIdentity = sourceResolver.wallpaperIdentity(for: currentDisplay)
            let currentWorkspaceURL = NSWorkspace.shared.desktopImageURL(for: screen)
            guard currentSpaceUUID == result.expectedSpaceUUID,
                  currentDisplay.pixelSize == result.display.pixelSize,
                  WallpaperCurrentness.isCurrent(
                      expected: result.sourceIdentity,
                      storeIdentity: currentStoreIdentity,
                      workspaceURL: currentWorkspaceURL,
                      generatedDirectory: generatedDirectory
                  ) else {
                try? fileManager.removeItem(at: result.outputURL)
                skippedStaleResult = true
                continue
            }

            do {
                try NSWorkspace.shared.setDesktopImageURL(
                    result.outputURL,
                    for: screen,
                    options: generatedWallpaperOptions
                )

                deletePreviousGeneratedFile(
                    for: result.display,
                    spaceUUID: result.spaceUUID,
                    replacedBy: result.outputURL,
                    in: saved
                )

                var stored = result.storedDesktop
                stored.generatedPath = result.outputURL.standardizedFileURL.path

                Self.saveDesktop(
                    stored,
                    for: result.display,
                    spaceUUID: result.spaceUUID,
                    in: &saved
                )
            } catch {
                try? fileManager.removeItem(at: result.outputURL)
                failures.append("\(screen.localizedName): \(error.localizedDescription)")
            }
        }

        storedDesktops = saved

        lastUnsupported = outcome.unsupported.first

        if failures.isEmpty {
            lastError = nil
            if !outcome.results.isEmpty {
                lastSuccessfulApplyDate = Date()
            }
        } else {
            lastError = failures.joined(separator: "; ")
        }

        isApplying = false
        notifyStateChanged()

        if reapplyRequested {
            reapplyRequested = false
            scheduleRefresh(force: true, delay: 0)
        } else if skippedStaleResult {
            scheduleRefresh(force: true, delay: 0.5)
        }
    }

    nonisolated private static func generate(
        inputs: [ScreenInput],
        saved: [String: StoredDesktop],
        generatedDirectory: URL
    ) -> GenerationOutcome {
        let renderer = WallpaperRenderer()
        let resolver = WallpaperStoreResolver()
        var results: [ScreenResult] = []
        var failures: [String] = []
        var unsupported: [String] = []

        for input in inputs {
            let display = input.display

            let prepared: PreparedWallpaper
            switch preparedWallpaperSource(
                for: input,
                saved: saved,
                resolver: resolver,
                generatedDirectory: generatedDirectory
            ) {
            case .success(let result):
                prepared = result
            case .failure(let error):
                if error.domain == unsupportedWallpaperErrorDomain {
                    unsupported.append(error.localizedDescription)
                } else {
                    failures.append("\(display.localizedName): \(error.localizedDescription)")
                }
                continue
            }

            do {
                let outputURL = generatedWallpaperURL(
                    for: display,
                    source: prepared.originalURL,
                    generatedDirectory: generatedDirectory
                )
                try renderer.render(
                    sourceURL: prepared.renderSource.renderURL,
                    outputURL: outputURL,
                    display: display,
                    desktopOptions: prepared.storedDesktop.renderOptions,
                    settings: input.settings,
                    textureURL: input.textureURL
                )

                results.append(
                    ScreenResult(
                        display: display,
                        outputURL: outputURL,
                        storedDesktop: prepared.storedDesktop,
                        spaceUUID: prepared.spaceUUID,
                        expectedSpaceUUID: input.spaceUUID,
                        sourceIdentity: prepared.sourceIdentity
                    )
                )
            } catch {
                failures.append("\(display.localizedName): \(error.localizedDescription)")
            }
        }

        return GenerationOutcome(results: results, failures: failures, unsupported: unsupported)
    }

    nonisolated private static func preparedWallpaperSource(
        for input: ScreenInput,
        saved: [String: StoredDesktop],
        resolver: WallpaperStoreResolver,
        generatedDirectory: URL
    ) -> Result<PreparedWallpaper, NSError> {
        let display = input.display
        let workspaceURL = input.workspaceURL
        let storeSource = resolver.wallpaperSource(for: display)
        let resolvedSource = storeSource.source
        let resolvedURL = resolvedSource?.originalURL
        // A new Space can be visible in SkyLight before it exists in Index.plist. Keep the
        // controller's active UUID so recovered/current NSWorkspace data is saved for that
        // new Space rather than in the display-wide legacy slot.
        let sourceSpaceUUID = resolvedSource?.spaceUUID ?? input.spaceUUID

        if case .blocked(let reason) = storeSource {
            return .failure(sourceError(reason))
        }

        // A video wallpaper has no still that macOS would accept back, so falling through
        // to the NSWorkspace URL here would replace it with a frozen frame for good.
        if case .unsupported(let reason) = storeSource {
            return .failure(unsupportedError(reason))
        }

        guard let currentURL = resolvedURL ?? workspaceURL else {
            return .failure(sourceError("no wallpaper URL"))
        }

        // NSWorkspace reports the aerial placeholder still for a video wallpaper, so this
        // also covers the fallback path where the store gave nothing usable.
        if WallpaperStoreResolver.isDynamicWallpaperPlaceholder(currentURL) {
            return .failure(unsupportedError(WallpaperStoreResolver.videoWallpaperReason))
        }

        let currentIsGenerated = [workspaceURL, resolvedURL]
            .compactMap { $0 }
            .contains { isGeneratedWallpaperURL($0, generatedDirectory: generatedDirectory) }

        if currentIsGenerated,
           let resolvedURL,
           let resolvedSource,
           !isGeneratedWallpaperURL(resolvedURL, generatedDirectory: generatedDirectory) {
            let storedDesktop = StoredDesktop.capture(
                url: resolvedURL,
                options: input.options,
                sourceIdentity: resolvedSource.identity
            )
            return .success(
                PreparedWallpaper(
                    storedDesktop: storedDesktop,
                    renderSource: resolvedSource,
                    originalURL: resolvedURL,
                    spaceUUID: sourceSpaceUUID,
                    sourceIdentity: resolvedSource.identity
                )
            )
        }

        if currentIsGenerated {
            let existing = GeneratedWallpaperRecovery.storedDesktop(
                matching: currentURL,
                displayIDs: [display.id, display.legacyID],
                in: saved
            ) ?? savedDesktop(
                for: display,
                spaceUUID: sourceSpaceUUID,
                in: saved
            )
            guard let existing, let existingURL = existing.url,
                  !isGeneratedWallpaperURL(existingURL, generatedDirectory: generatedDirectory) else {
                return .failure(sourceError("original wallpaper is not available"))
            }

            switch resolver.preparedSource(originalURL: existingURL, for: display) {
            case .resolved(let preparedSource):
                let recoveredIdentity = existing.sourceIdentity
                    .flatMap(WallpaperIdentity.init(stableIdentifier:))
                    ?? preparedSource.identity
                var recoveredDesktop = existing
                recoveredDesktop.urlString = preparedSource.originalURL.absoluteString
                recoveredDesktop.sourceIdentity = recoveredIdentity.stableIdentifier
                return .success(
                    PreparedWallpaper(
                        storedDesktop: recoveredDesktop,
                        renderSource: preparedSource,
                        originalURL: preparedSource.originalURL,
                        spaceUUID: sourceSpaceUUID,
                        sourceIdentity: recoveredIdentity
                    )
                )
            case .blocked(let reason):
                return .failure(sourceError(reason))
            case .unsupported(let reason):
                return .failure(unsupportedError(reason))
            case .unavailable:
                return .failure(sourceError("original wallpaper is not available"))
            }
        }

        let fallbackIdentity = WallpaperIdentity.file(currentURL)
        let storedDesktop = StoredDesktop.capture(
            url: currentURL,
            options: input.options,
            sourceIdentity: resolvedSource?.identity ?? fallbackIdentity
        )

        if let resolvedSource {
            return .success(
                PreparedWallpaper(
                    storedDesktop: storedDesktop,
                    renderSource: resolvedSource,
                    originalURL: currentURL,
                    spaceUUID: sourceSpaceUUID,
                    sourceIdentity: resolvedSource.identity
                )
            )
        }

        switch resolver.preparedSource(originalURL: currentURL, for: display) {
        case .resolved(let preparedSource):
            var preparedDesktop = storedDesktop
            preparedDesktop.urlString = preparedSource.originalURL.absoluteString
            preparedDesktop.sourceIdentity = preparedSource.identity.stableIdentifier
            return .success(
                PreparedWallpaper(
                    storedDesktop: preparedDesktop,
                    renderSource: preparedSource,
                    originalURL: preparedSource.originalURL,
                    spaceUUID: sourceSpaceUUID,
                    sourceIdentity: preparedSource.identity
                )
            )
        case .blocked(let reason):
            return .failure(sourceError(reason))
        case .unsupported(let reason):
            return .failure(unsupportedError(reason))
        case .unavailable:
            return .failure(sourceError("wallpaper source is not available"))
        }
    }

    nonisolated private static func unsupportedError(_ message: String) -> NSError {
        NSError(
            domain: unsupportedWallpaperErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    nonisolated private static func sourceError(_ message: String) -> NSError {
        NSError(
            domain: "WandelBar.WallpaperSource",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func shouldRefreshGeneratedWallpapers() -> Bool {
        let saved = storedDesktops

        for screen in NSScreen.screens {
            let display = DisplaySnapshot(screen: screen)
            if sourceResolver.activeSpaceContext(for: display)?.isFullscreen == true {
                continue
            }

            let activeSpaceUUID = sourceResolver.activeSpaceUUID(for: display)
            guard settingsStore.isEffectEnabled(for: activeSpaceUUID) else { continue }
            let stored = Self.savedDesktop(
                for: display,
                spaceUUID: activeSpaceUUID,
                in: saved
            )
            if WallpaperRefreshPolicy.shouldRefresh(
                workspaceURL: NSWorkspace.shared.desktopImageURL(for: screen),
                storeIdentity: sourceResolver.wallpaperIdentity(for: display),
                savedSourceIdentity: stored?.sourceIdentity,
                savedURL: stored?.url,
                generatedDirectory: generatedDirectory
            ) {
                return true
            }
        }

        return false
    }

    private func scheduleRefresh(force: Bool, delay: TimeInterval) {
        guard isEnabled,
              !isStopping,
              isSessionActive,
              !lockScreenWallpaperCoordinator.isPresentingOriginal else { return }

        generationRevision &+= 1
        pendingRefresh?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.applyBlurredWallpapers(force: force)
            }
        }

        pendingRefresh = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleRestoreOriginals(delay: TimeInterval) {
        guard !isEnabled, shouldRestoreOriginalsOnSpaceChange, isSessionActive else { return }

        pendingRestore?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.restoreOriginals(
                    removeRestoredEntries: true,
                    onlyGeneratedCurrentWallpapers: true
                )
            }
        }

        pendingRestore = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startTimer() {
        guard refreshTimer == nil else { return }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.applyBlurredWallpapers(force: false)
            }
        }
    }

    @objc private func screenParametersDidChange() {
        if isEnabled {
            scheduleRefresh(force: true, delay: 1)
        } else {
            scheduleRestoreOriginals(delay: 1)
        }
    }

    @objc private func activeSpaceDidChange() {
        if isEnabled {
            scheduleRefresh(force: true, delay: 1)
        } else {
            scheduleRestoreOriginals(delay: 1)
        }
    }

    @objc private func sessionDidResignActive() {
        lockScreenWallpaperCoordinator.lock()
        isSessionActive = false
        generationRevision &+= 1
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingRestore?.cancel()
        pendingRestore = nil
        reapplyRequested = false
    }

    @objc private func sessionDidBecomeActive() {
        guard !isStopping else { return }

        isSessionActive = true
        lockScreenWallpaperCoordinator.unlock()
        if isEnabled {
            scheduleRefresh(force: true, delay: 0.5)
        } else {
            scheduleRestoreOriginals(delay: 0.5)
        }
    }

    private func lockScreenDidLock() {
        lockScreenWallpaperCoordinator.lock()
    }

    private func lockScreenDidUnlock() {
        lockScreenWallpaperCoordinator.unlock()
        if isEnabled, isSessionActive {
            scheduleRefresh(force: true, delay: 0.5)
        }
    }

    private func applyLockScreenWallpaperTransition(_ transition: LockScreenWallpaperTransition) {
        if transition == .lock {
            generationRevision &+= 1
            pendingRefresh?.cancel()
            pendingRefresh = nil
            reapplyRequested = false
        }

        let saved = storedDesktops
        var failures: [String] = []

        for screen in NSScreen.screens {
            let display = DisplaySnapshot(screen: screen)
            if sourceResolver.activeSpaceContext(for: display)?.isFullscreen == true {
                continue
            }

            let activeSpaceUUID = sourceResolver.activeSpaceUUID(for: display)
            guard settingsStore.isEffectEnabled(for: activeSpaceUUID) else { continue }
            guard let storedEntry = Self.savedDesktopEntry(
                for: display,
                spaceUUID: activeSpaceUUID,
                in: saved
            ) else { continue }

            let stored = storedEntry.desktop
            let generatedExists = stored.generatedPath.map(fileManager.fileExists(atPath:)) ?? false
            guard let targetURL = LockScreenWallpaperPolicy.targetURL(
                for: transition,
                currentURL: NSWorkspace.shared.desktopImageURL(for: screen),
                storedDesktop: stored,
                generatedDirectory: generatedDirectory,
                generatedFileExists: generatedExists
            ) else { continue }

            if targetURL.isFileURL, !fileManager.fileExists(atPath: targetURL.path) {
                continue
            }

            let options = transition == .lock
                ? stored.workspaceOptions
                : generatedWallpaperOptions
            do {
                try NSWorkspace.shared.setDesktopImageURL(targetURL, for: screen, options: options)
            } catch {
                failures.append("\(screen.localizedName): \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            lastError = failures.joined(separator: "; ")
            notifyStateChanged()
        }
    }

    private var storedDesktops: [String: StoredDesktop] {
        get {
            guard let data = defaults.data(forKey: DefaultsKey.storedDesktops) else {
                return [:]
            }

            return (try? JSONDecoder().decode([String: StoredDesktop].self, from: data)) ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: DefaultsKey.storedDesktops)
            }
        }
    }

    private var generatedWallpaperOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
        [
            .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
            .allowClipping: false
        ]
    }

    private func screen(forDisplayID id: String) -> NSScreen? {
        NSScreen.screens.first { DisplaySnapshot(screen: $0).id == id }
    }

    nonisolated private static func savedDesktop(
        for display: DisplaySnapshot,
        spaceUUID: String?,
        in saved: [String: StoredDesktop]
    ) -> StoredDesktop? {
        savedDesktopEntry(for: display, spaceUUID: spaceUUID, in: saved)?.desktop
    }

    nonisolated private static func savedDesktopEntry(
        for display: DisplaySnapshot,
        spaceUUID: String?,
        in saved: [String: StoredDesktop]
    ) -> (key: String, desktop: StoredDesktop)? {
        if let spaceUUID {
            for key in desktopStorageKeys(for: display, spaceUUID: spaceUUID) {
                if let desktop = saved[key] {
                    return (key, desktop)
                }
            }
        }

        for key in desktopStorageKeys(for: display, spaceUUID: nil) {
            if let desktop = saved[key] {
                return (key, desktop)
            }
        }

        return nil
    }

    nonisolated private static func saveDesktop(
        _ desktop: StoredDesktop,
        for display: DisplaySnapshot,
        spaceUUID: String?,
        in saved: inout [String: StoredDesktop]
    ) {
        saved[desktopStorageKey(for: display, spaceUUID: spaceUUID)] = desktop

        if display.legacyID != display.id {
            saved.removeValue(forKey: display.legacyID)
            if let spaceUUID {
                saved.removeValue(forKey: "\(display.legacyID)::\(spaceUUID)")
            }
        }
    }

    nonisolated private static func desktopStorageKey(for display: DisplaySnapshot, spaceUUID: String?) -> String {
        desktopStorageKeys(for: display, spaceUUID: spaceUUID)[0]
    }

    nonisolated private static func desktopStorageKeys(for display: DisplaySnapshot, spaceUUID: String?) -> [String] {
        if let spaceUUID {
            return uniqueKeys([
                "\(display.id)::\(spaceUUID)",
                "\(display.legacyID)::\(spaceUUID)"
            ])
        }

        return uniqueKeys([display.id, display.legacyID])
    }

    nonisolated private static func uniqueKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// Removes a stored entry and deletes the generated file it referenced.
    private func removeStoredEntry(_ key: String, from saved: inout [String: StoredDesktop]) {
        if let path = saved[key]?.generatedPath {
            removeGeneratedFile(atPath: path)
        }
        saved.removeValue(forKey: key)
    }

    /// Deletes the generated file previously applied for this display/space when it is
    /// being replaced, so at most one generated file exists per display+Space pair.
    private func deletePreviousGeneratedFile(
        for display: DisplaySnapshot,
        spaceUUID: String?,
        replacedBy newURL: URL,
        in saved: [String: StoredDesktop]
    ) {
        guard let previous = Self.savedDesktopEntry(for: display, spaceUUID: spaceUUID, in: saved)?.desktop,
              let previousPath = previous.generatedPath else {
            return
        }

        let standardizedPreviousPath = URL(fileURLWithPath: previousPath).standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        if standardizedPreviousPath != newPath {
            removeGeneratedFile(atPath: previousPath)
        }
    }

    private func removeGeneratedFile(atPath path: String) {
        let url = URL(fileURLWithPath: path)
        guard GeneratedWallpaperPaths.contains(url, in: generatedDirectory) else {
            return
        }
        try? fileManager.removeItem(at: url)
    }

    /// Removes generated files that are no longer referenced by any stored desktop or
    /// currently applied on a connected display. Bounds unbounded on-disk growth.
    private func pruneOrphanedGeneratedFiles() {
        var keep = Set<String>()

        for desktop in storedDesktops.values {
            if let path = desktop.generatedPath {
                keep.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }

        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen),
               isGeneratedWallpaperURL(url) {
                keep.insert(url.standardizedFileURL.path)
            }
        }

        guard let files = try? fileManager.contentsOfDirectory(
            at: generatedDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files where !keep.contains(file.standardizedFileURL.path) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Removes unreferenced QuickLook/Photos source copies that have not been touched recently.
    /// Referenced originals are recovery data and must outlive the generated wallpaper.
    private func pruneStaleOriginalCaches() {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        let directories = [
            applicationSupportDirectory.appendingPathComponent("Originals/QuickLook", isDirectory: true),
            applicationSupportDirectory.appendingPathComponent("Originals/Photos", isDirectory: true)
        ]
        let storedURLs = storedDesktops.values.compactMap(\.url)
        let currentURLs = NSScreen.screens.compactMap {
            NSWorkspace.shared.desktopImageURL(for: $0)
        }

        OriginalCachePruner(fileManager: fileManager).prune(
            directories: directories,
            preserving: storedURLs + currentURLs,
            olderThan: cutoff
        )
    }

    nonisolated private static func generatedWallpaperURL(
        for display: DisplaySnapshot,
        source: URL,
        generatedDirectory: URL
    ) -> URL {
        let sourceName = source.deletingPathExtension().lastPathComponent
        let safeSourceName = sourceName
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
            .prefix(42)

        let size = display.pixelSize
        // A unique URL forces macOS to reload rapid consecutive changes instead of reusing
        // its desktop-image cache for a file overwritten within the same second.
        let generationID = UUID().uuidString.lowercased()
        let fileName = "display-\(display.id)-\(Int(size.width))x\(Int(size.height))-\(safeSourceName)-\(generationID).jpg"
        return generatedDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    nonisolated private static func isGeneratedWallpaperURL(_ url: URL, generatedDirectory: URL) -> Bool {
        GeneratedWallpaperPaths.contains(url, in: generatedDirectory)
    }

    private func isGeneratedWallpaperURL(_ url: URL) -> Bool {
        Self.isGeneratedWallpaperURL(url, generatedDirectory: generatedDirectory)
    }

    private func currentWallpaperIsGenerated(for screen: NSScreen) -> Bool {
        let display = DisplaySnapshot(screen: screen)
        return [
            NSWorkspace.shared.desktopImageURL(for: screen),
            sourceResolver.wallpaperIdentity(for: display)?.fileURL
        ]
            .compactMap { $0 }
            .contains { isGeneratedWallpaperURL($0) }
    }

    private func discardGeneratedFiles(in outcome: GenerationOutcome) {
        for result in outcome.results {
            try? fileManager.removeItem(at: result.outputURL)
        }
    }

    private func ensureSupportDirectories() {
        try? fileManager.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
    }

    private func notifyStateChanged() {
        onStateChanged?()
    }
}

private struct PreparedWallpaper {
    var storedDesktop: StoredDesktop
    var renderSource: WallpaperSource
    var originalURL: URL
    var spaceUUID: String?
    var sourceIdentity: WallpaperIdentity
}

private struct ScreenInput: Sendable {
    var display: DisplaySnapshot
    var spaceUUID: String?
    var workspaceURL: URL?
    var options: DesktopOptionsSnapshot
    var settings: WallpaperEffectSettings
    var textureURL: URL?
}

private struct ScreenResult: Sendable {
    var display: DisplaySnapshot
    var outputURL: URL
    var storedDesktop: StoredDesktop
    var spaceUUID: String?
    var expectedSpaceUUID: String?
    var sourceIdentity: WallpaperIdentity
}

private struct GenerationOutcome: Sendable {
    var results: [ScreenResult]
    var failures: [String]
    var unsupported: [String]
}
