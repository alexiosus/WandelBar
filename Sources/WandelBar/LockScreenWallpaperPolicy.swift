import AppKit
import Foundation

extension Notification.Name {
    static let blurBarScreenIsLocked = Notification.Name("com.apple.screenIsLocked")
    static let blurBarScreenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")
}

enum LockScreenWallpaperTransition: Equatable {
    case lock
    case unlock
}

@MainActor
final class LockScreenWallpaperCoordinator {
    private let isEnabled: () -> Bool
    private let dontApplyOnLockScreen: () -> Bool
    private let apply: (LockScreenWallpaperTransition) -> Void
    private var policy = LockScreenWallpaperPolicy()

    init(
        isEnabled: @escaping () -> Bool,
        dontApplyOnLockScreen: @escaping () -> Bool,
        apply: @escaping (LockScreenWallpaperTransition) -> Void
    ) {
        self.isEnabled = isEnabled
        self.dontApplyOnLockScreen = dontApplyOnLockScreen
        self.apply = apply
    }

    var isPresentingOriginal: Bool {
        policy.isPresentingOriginal
    }

    func lock() {
        guard policy.begin(
            enabled: isEnabled(),
            dontApplyOnLockScreen: dontApplyOnLockScreen()
        ) else { return }
        apply(.lock)
    }

    func unlock() {
        guard policy.end() else { return }
        guard isEnabled() else { return }
        apply(.unlock)
    }
}

struct LockScreenWallpaperPolicy {
    private(set) var isPresentingOriginal = false

    mutating func begin(enabled: Bool, dontApplyOnLockScreen: Bool) -> Bool {
        guard enabled, dontApplyOnLockScreen, !isPresentingOriginal else { return false }
        isPresentingOriginal = true
        return true
    }

    mutating func end() -> Bool {
        guard isPresentingOriginal else { return false }
        isPresentingOriginal = false
        return true
    }

    static func targetURL(
        for transition: LockScreenWallpaperTransition,
        currentURL: URL?,
        storedDesktop: StoredDesktop,
        generatedDirectory: URL,
        generatedFileExists: Bool
    ) -> URL? {
        guard let originalURL = storedDesktop.url,
              let generatedPath = storedDesktop.generatedPath else {
            return nil
        }

        let generatedURL = URL(fileURLWithPath: generatedPath).standardizedFileURL
        guard GeneratedWallpaperPaths.contains(generatedURL, in: generatedDirectory) else {
            return nil
        }

        switch transition {
        case .lock:
            guard currentURL?.standardizedFileURL == generatedURL else { return nil }
            return originalURL
        case .unlock:
            guard generatedFileExists,
                  currentURL?.standardizedFileURL == originalURL.standardizedFileURL else {
                return nil
            }
            return generatedURL
        }
    }
}

@MainActor
final class LockScreenEventMonitor: NSObject {
    private let sessionCenter: NotificationCenter
    private let screenCenter: NotificationCenter
    private let onLock: () -> Void
    private let onUnlock: () -> Void
    private var isStarted = false

    init(
        sessionCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        screenCenter: NotificationCenter = DistributedNotificationCenter.default(),
        onLock: @escaping () -> Void,
        onUnlock: @escaping () -> Void
    ) {
        self.sessionCenter = sessionCenter
        self.screenCenter = screenCenter
        self.onLock = onLock
        self.onUnlock = onUnlock
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        screenCenter.addObserver(
            self,
            selector: #selector(didLock),
            name: .blurBarScreenIsLocked,
            object: nil
        )
        screenCenter.addObserver(
            self,
            selector: #selector(didUnlock),
            name: .blurBarScreenIsUnlocked,
            object: nil
        )
        sessionCenter.addObserver(
            self,
            selector: #selector(didLock),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        sessionCenter.addObserver(
            self,
            selector: #selector(didUnlock),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    func stop() {
        guard isStarted else { return }
        screenCenter.removeObserver(self)
        sessionCenter.removeObserver(self)
        isStarted = false
    }

    @objc private func didLock() {
        onLock()
    }

    @objc private func didUnlock() {
        onUnlock()
    }
}
