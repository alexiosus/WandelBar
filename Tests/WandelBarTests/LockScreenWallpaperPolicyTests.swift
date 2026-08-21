import AppKit
import Foundation
import Testing
@testable import WandelBar

@Test @MainActor func lockScreenEventMonitorMapsExactAndFallbackNotifications() {
    let sessionCenter = NotificationCenter()
    let screenCenter = NotificationCenter()
    var events: [LockScreenWallpaperTransition] = []
    let monitor = LockScreenEventMonitor(
        sessionCenter: sessionCenter,
        screenCenter: screenCenter,
        onLock: { events.append(.lock) },
        onUnlock: { events.append(.unlock) }
    )
    monitor.start()

    screenCenter.post(name: .blurBarScreenIsLocked, object: nil)
    screenCenter.post(name: .blurBarScreenIsUnlocked, object: nil)
    sessionCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    sessionCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

    #expect(events == [.lock, .unlock, .lock, .unlock])

    monitor.stop()
    screenCenter.post(name: .blurBarScreenIsLocked, object: nil)
    #expect(events == [.lock, .unlock, .lock, .unlock])
}

@Test @MainActor func lockScreenCoordinatorAppliesEachTransitionOnce() {
    var isEnabled = true
    var dontApplyOnLockScreen = true
    var transitions: [LockScreenWallpaperTransition] = []
    let coordinator = LockScreenWallpaperCoordinator(
        isEnabled: { isEnabled },
        dontApplyOnLockScreen: { dontApplyOnLockScreen },
        apply: { transitions.append($0) }
    )

    coordinator.lock()
    coordinator.lock()
    coordinator.unlock()
    coordinator.unlock()
    #expect(transitions == [.lock, .unlock])

    isEnabled = false
    coordinator.lock()
    isEnabled = true
    dontApplyOnLockScreen = false
    coordinator.lock()
    #expect(transitions == [.lock, .unlock])
}

@Test @MainActor func lockScreenCoordinatorDoesNotReapplyAfterWandelBarIsDisabled() {
    var isEnabled = true
    var transitions: [LockScreenWallpaperTransition] = []
    let coordinator = LockScreenWallpaperCoordinator(
        isEnabled: { isEnabled },
        dontApplyOnLockScreen: { true },
        apply: { transitions.append($0) }
    )

    coordinator.lock()
    isEnabled = false
    coordinator.unlock()

    #expect(transitions == [.lock])
    #expect(!coordinator.isPresentingOriginal)
}

@Test func lockScreenPolicyCoalescesDuplicateTransitions() {
    var policy = LockScreenWallpaperPolicy()

    let disabledBegin = policy.begin(enabled: false, dontApplyOnLockScreen: true)
    let preferenceOffBegin = policy.begin(enabled: true, dontApplyOnLockScreen: false)
    let firstBegin = policy.begin(enabled: true, dontApplyOnLockScreen: true)
    #expect(!disabledBegin)
    #expect(!preferenceOffBegin)
    #expect(firstBegin)
    #expect(policy.isPresentingOriginal)
    let duplicateBegin = policy.begin(enabled: true, dontApplyOnLockScreen: true)
    let firstEnd = policy.end()
    #expect(!duplicateBegin)
    #expect(firstEnd)
    #expect(!policy.isPresentingOriginal)
    let duplicateEnd = policy.end()
    #expect(!duplicateEnd)
}

@Test func lockScreenTransitionOnlySwapsItsOwnWallpaperPair() {
    let generatedDirectory = URL(fileURLWithPath: "/tmp/WandelBar/Generated", isDirectory: true)
    let original = URL(fileURLWithPath: "/Pictures/original.jpg")
    let generated = generatedDirectory.appendingPathComponent("display-space.jpg")
    var stored = StoredDesktop.capture(
        url: original,
        options: DesktopOptionsSnapshot(options: [:])
    )
    stored.generatedPath = generated.path

    #expect(LockScreenWallpaperPolicy.targetURL(
        for: .lock,
        currentURL: generated,
        storedDesktop: stored,
        generatedDirectory: generatedDirectory,
        generatedFileExists: true
    ) == original)
    #expect(LockScreenWallpaperPolicy.targetURL(
        for: .unlock,
        currentURL: original,
        storedDesktop: stored,
        generatedDirectory: generatedDirectory,
        generatedFileExists: true
    ) == generated)
    #expect(LockScreenWallpaperPolicy.targetURL(
        for: .lock,
        currentURL: URL(fileURLWithPath: "/Pictures/replacement.jpg"),
        storedDesktop: stored,
        generatedDirectory: generatedDirectory,
        generatedFileExists: true
    ) == nil)
    #expect(LockScreenWallpaperPolicy.targetURL(
        for: .unlock,
        currentURL: original,
        storedDesktop: stored,
        generatedDirectory: generatedDirectory,
        generatedFileExists: false
    ) == nil)

    stored.generatedPath = "/tmp/WandelBar/Generated-Backup/escaped.jpg"
    #expect(LockScreenWallpaperPolicy.targetURL(
        for: .unlock,
        currentURL: original,
        storedDesktop: stored,
        generatedDirectory: generatedDirectory,
        generatedFileExists: true
    ) == nil)
}

@Test @MainActor func lockScreenPreferencePersistsAcrossControllerInstances() {
    let suiteName = "WandelBarTests.LockScreenPreference.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = WallpaperController(defaults: defaults)
    #expect(!first.dontApplyOnLockScreen)

    first.setDontApplyOnLockScreen(true)

    let reloaded = WallpaperController(defaults: defaults)
    #expect(reloaded.dontApplyOnLockScreen)
}
