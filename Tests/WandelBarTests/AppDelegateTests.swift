import AppKit
import Testing
@testable import WandelBar

@MainActor
@Test func reopeningApplicationShowsTheExistingPopover() {
    let presenter = RecordingMenuBarPopoverPresenter()
    let delegate = AppDelegate(menuBarPresenter: presenter)

    let shouldHandleNormally = delegate.applicationShouldHandleReopen(
        NSApplication.shared,
        hasVisibleWindows: false
    )

    #expect(!shouldHandleNormally)
    #expect(presenter.showPopoverCallCount == 1)
}

@MainActor
private final class RecordingMenuBarPopoverPresenter: MenuBarPopoverPresenting {
    private(set) var showPopoverCallCount = 0

    func showPopover() {
        showPopoverCallCount += 1
    }
}
