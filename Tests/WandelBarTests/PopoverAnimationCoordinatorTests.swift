import AppKit
import Testing
@testable import WandelBar

@Test @MainActor func popoverOnlyDisablesAnimationWhileItsContentIsVisible() {
    let popover = NSPopover()
    let coordinator = PopoverAnimationCoordinator()

    coordinator.attach(to: popover)
    #expect(popover.delegate === coordinator)
    #expect(popover.animates)

    coordinator.popoverDidShow(
        Notification(name: NSPopover.didShowNotification, object: popover)
    )
    #expect(!popover.animates)

    coordinator.popoverWillClose(
        Notification(name: NSPopover.willCloseNotification, object: popover)
    )
    #expect(popover.animates)
}
