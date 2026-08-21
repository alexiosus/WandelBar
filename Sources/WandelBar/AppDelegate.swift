import AppKit
import SwiftUI

@MainActor
protocol MenuBarPopoverPresenting: AnyObject {
    func showPopover()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = WallpaperController()
    private var menuBarPresenter: (any MenuBarPopoverPresenting)?

    init(menuBarPresenter: (any MenuBarPopoverPresenting)? = nil) {
        self.menuBarPresenter = menuBarPresenter
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if menuBarPresenter == nil {
            menuBarPresenter = MenuBarController(controller: controller)
        }
        controller.start()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        menuBarPresenter?.showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

/// Keeps the popover's arrow and top edge stationary while SwiftUI changes the
/// preferred content height. AppKit's default animation interpolates the complete
/// popover frame; disabling it only while shown avoids that jump without removing the
/// normal show and close animations.
@MainActor
final class PopoverAnimationCoordinator: NSObject, NSPopoverDelegate {
    func attach(to popover: NSPopover) {
        popover.delegate = self
        popover.animates = true
    }

    func popoverDidShow(_ notification: Notification) {
        (notification.object as? NSPopover)?.animates = false
    }

    func popoverWillClose(_ notification: Notification) {
        (notification.object as? NSPopover)?.animates = true
    }
}

@MainActor
private final class MenuBarController: NSObject, MenuBarPopoverPresenting {
    private let controller: WallpaperController
    private let statusItem: NSStatusItem
    private let popoverAnimationCoordinator = PopoverAnimationCoordinator()
    private lazy var popoverModel = MenuBarPopoverModel(controller: controller)
    private lazy var dialogController = MenuBarDialogController(
        model: popoverModel,
        dismissPopover: { [weak self] in self?.closePopover() },
        restorePopover: { [weak self] in self?.showPopover() }
    )
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: MenuBarPopoverView(model: popoverModel))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popoverAnimationCoordinator.attach(to: popover)
        return popover
    }()

    init(controller: WallpaperController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        controller.onStateChanged = { [weak self] in
            self?.popoverModel.reloadFromController()
            self?.updateStatusIcon()
        }

        popoverModel.dialogPresenter = dialogController

        configureStatusItem()
        updateStatusIcon()
    }

    private func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        button.image = MenuBarStatusIcon.image(for: controller.state)
        button.imagePosition = .imageOnly
        button.toolTip = controller.statusText
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        handlePopoverPresentation(.menuBarClick)
    }

    func showPopover() {
        handlePopoverPresentation(.applicationReopen)
    }

    private func handlePopoverPresentation(_ trigger: PopoverPresentationTrigger) {
        guard let button = statusItem.button else { return }

        let action = PopoverPresentationPolicy.action(for: trigger, isShown: popover.isShown)
        if action == .close {
            popover.performClose(button)
            return
        }

        controller.setEditingScreen(button.window?.screen)
        controller.refreshWallpaperSupport()
        popoverModel.reloadFromController()
        NSApp.activate(ignoringOtherApps: true)
        if action == .show {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        focusPopoverWindow()
    }

    private func focusPopoverWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeKey()
        }
    }
}
