import AppKit
import SwiftUI

/// File pickers and package dialogs run outside the popover. An `NSPopover` is transient:
/// it closes the moment a panel takes key, which left the old in-popover flows showing a
/// detached popover after export and no popover at all after import.
@MainActor
protocol MenuBarDialogPresenting: AnyObject {
    func presentTextureImport()
    func presentPresetImport()
    func presentPresetExport()
}

@MainActor
final class MenuBarDialogController: NSObject, MenuBarDialogPresenting, NSWindowDelegate {
    private let model: MenuBarPopoverModel
    private let dismissPopover: () -> Void
    private let restorePopover: () -> Void
    private var window: NSWindow?

    init(
        model: MenuBarPopoverModel,
        dismissPopover: @escaping () -> Void,
        restorePopover: @escaping () -> Void
    ) {
        self.model = model
        self.dismissPopover = dismissPopover
        self.restorePopover = restorePopover
        super.init()
    }

    // MARK: - Textures

    /// Texture import has no follow-up dialog, so the popover is brought back afterwards —
    /// the user picked an image to see it applied in the controls they just left.
    func presentTextureImport() {
        dismissPopover()

        let panel = NSOpenPanel()
        panel.title = "Choose Texture"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]

        begin(panel) { [weak self] url in
            guard let self else { return }
            guard let url else {
                self.restorePopover()
                return
            }

            Task { @MainActor in
                await self.model.importTexture(from: url)
                self.restorePopover()
            }
        }
    }

    // MARK: - Preset packages

    func presentPresetExport() {
        dismissPopover()
        model.beginPresetExportSelection()

        let model = self.model
        presentWindow(title: "Export Presets") { [weak self] in
            PresetExportView(
                model: model,
                onChooseDestination: { self?.chooseExportDestination() },
                onCancel: { self?.closeWindow() }
            )
        }
    }

    func presentPresetImport() {
        dismissPopover()

        let panel = NSOpenPanel()
        panel.title = "Import Preset Package"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.wandelBarPresetPackage]

        begin(panel) { [weak self] url in
            guard let self, let url else { return }

            Task { @MainActor in
                await self.model.preparePresetImport(from: url)
                guard let preview = self.model.importPreview else {
                    self.presentPackageMessage()
                    return
                }

                self.presentWindow(title: "Import Presets") { [weak self] in
                    PresetImportPreviewView(
                        preview: preview,
                        onImport: { self?.commitImport() },
                        onCancel: { self?.closeWindow() }
                    )
                }
            }
        }
    }

    private func chooseExportDestination() {
        guard let window else { return }

        let panel = NSSavePanel()
        panel.title = "Export Presets"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.wandelBarPresetPackage]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultExportName

        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }

                Task { @MainActor in
                    await self.model.exportSelectedPresets(to: url)
                    self.closeWindow()
                    self.presentPackageMessage()
                }
            }
        }
    }

    private func commitImport() {
        model.commitPresetImport()
        closeWindow()
        presentPackageMessage()
    }

    private var defaultExportName: String {
        let selected = model.userPresets.filter { model.exportPresetIDs.contains($0.id) }
        let base = selected.count == 1 ? selected[0].name : "WandelBar Presets"
        let safe = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe).wandelbar-presets"
    }

    // MARK: - Presentation

    private func begin(_ panel: NSOpenPanel, completion: @escaping (URL?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            MainActor.assumeIsolated {
                completion(response == .OK ? panel.url : nil)
            }
        }
    }

    private func presentWindow<Content: View>(
        title: String,
        content: () -> Content
    ) {
        closeWindow()

        let hosting = NSHostingController(rootView: content())
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        guard let window else { return }
        self.window = nil
        window.delegate = nil
        window.close()
        model.cancelPresetImport()
    }

    /// Export and import report through an alert rather than the popover, because the
    /// popover is closed for the whole flow and would swallow the message.
    private func presentPackageMessage() {
        guard let message = model.presetPackageError ?? model.presetPackageCompletion else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Preset Package"
        alert.informativeText = message
        alert.alertStyle = model.presetPackageError == nil ? .informational : .warning
        alert.addButton(withTitle: "OK")
        model.clearPresetPackageMessage()

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        model.cancelPresetImport()
    }
}
