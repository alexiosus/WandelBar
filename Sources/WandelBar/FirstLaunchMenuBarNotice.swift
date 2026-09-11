import AppKit

struct MenuBarSetupNoticeState {
    static let acknowledgedKey = "menuBarBackgroundSetupAcknowledged"
    let defaults: UserDefaults

    func shouldPresent(macOSMajorVersion: Int) -> Bool {
        macOSMajorVersion >= 26 && !defaults.bool(forKey: Self.acknowledgedKey)
    }

    func acknowledge() {
        defaults.set(true, forKey: Self.acknowledgedKey)
    }
}

@MainActor
enum FirstLaunchMenuBarNotice {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    static func presentIfNeeded() {
        let state = MenuBarSetupNoticeState(defaults: .standard)
        guard state.shouldPresent(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) else { return }
        let alert = NSAlert()
        alert.messageText = "Let WandelBar show through your menu bar"
        alert.informativeText = "In System Settings → Menu Bar, turn off “Show menu bar background” so macOS doesn’t cover WandelBar’s appearance. If it’s already off, you’re all set.\n\nThis reminder appears only once."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Menu Bar Settings")
        alert.addButton(withTitle: "Got It")
        let dock = DialogDockPresence()
        dock.show(current: NSApp.activationPolicy()) { NSApp.setActivationPolicy($0) }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        state.acknowledge()
        dock.restore { NSApp.setActivationPolicy($0) }
        if response == .alertFirstButtonReturn {
            if !NSWorkspace.shared.open(settingsURL) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            }
        }
    }
}
