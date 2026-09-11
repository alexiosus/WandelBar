import AppKit
import SwiftUI

@MainActor
protocol MenuBarDialogPresenting: AnyObject {
    func presentTextureImport()
    func presentPresetImport()
    func presentPresetExport()
    func presentAbout()
    func presentTextureManagement()
    func presentPresetSharing()
    func presentCommunityGallery()
}

extension MenuBarDialogPresenting {
    func presentAbout() {}
    func presentTextureManagement() {}
    func presentPresetSharing() {}
    func presentCommunityGallery() {}
}

/// Long operations use independent windows so closing a transient popover never loses a result.
@MainActor
final class MenuBarDialogController: NSObject, MenuBarDialogPresenting, NSWindowDelegate {
    private let model: MenuBarPopoverModel
    private let dismissPopover: () -> Void
    private let restorePopover: () -> Void
    private var window: NSWindow?
    private let dockPresence = DialogDockPresence()
    private var operation: Task<Void, Never>?
    private var operationID: UUID?

    init(model: MenuBarPopoverModel, dismissPopover: @escaping () -> Void, restorePopover: @escaping () -> Void) {
        self.model = model
        self.dismissPopover = dismissPopover
        self.restorePopover = restorePopover
        super.init()
    }

    func presentTextureImport() {
        dismissPopover()
        closeWindow()
        let panel = NSOpenPanel()
        panel.title = "Choose Texture"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        begin(panel) { [weak self] url in
            guard let self else { return }
            guard let url else { self.restorePopover(); return }
            Task { @MainActor in
                await self.model.importTexture(from: url)
                self.restorePopover()
            }
        }
    }

    func presentPresetExport() {
        dismissPopover()
        closeWindow()
        model.beginPresetExportSelection()
        replaceWindow(title: "Export Presets") {
            PresetExportView(model: model, onChooseDestination: { [weak self] in self?.chooseExportDestination() },
                onCancel: { [weak self] in self?.closeWindow() })
        }
    }

    func presentPresetImport() {
        dismissPopover()
        closeWindow()
        let panel = NSOpenPanel()
        panel.title = "Import Preset Package"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.wandelBarPresetPackage]
        begin(panel) { [weak self] url in
            guard let self, let url else { return }
            self.importPackage(at: url)
        }
    }

    func importPackage(at url: URL, removeAfter: Bool = false) {
        dismissPopover()
        startOperation(title: "Preparing Import", detail: "Validating package and rendering previews…") { [weak self] in
            defer { if removeAfter { try? FileManager.default.removeItem(at: url) } }
            guard let self else { return }
            await self.model.preparePresetImport(from: url)
            guard !Task.isCancelled else { return }
            guard let preview = self.model.importPreview else { self.presentPackageMessage(); return }
            self.replaceWindow(title: "Import Presets") {
                PresetImportPreviewView(preview: preview,
                    onImportSelection: { [weak self] ids in self?.installSelectedPresets(ids) },
                    onCancel: { [weak self] in self?.closeWindow() })
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
                self.startOperation(title: "Exporting Presets", detail: "Packaging presets and textures…") { [weak self] in
                    guard let self else { return }
                    await self.model.exportSelectedPresets(to: url)
                    guard !Task.isCancelled else { return }
                    self.presentPackageMessage()
                }
            }
        }
    }

    private func installSelectedPresets(_ ids: Set<String>) {
        startOperation(title: "Importing Presets", detail: "Installing selected presets and textures…", preserveImport: true) { [weak self] in
            guard let self else { return }
            await self.model.commitPresetImportInBackground(selectedIDs: ids)
            guard !Task.isCancelled else { return }
            self.presentPackageMessage()
        }
    }

    func presentAbout() {
        dismissPopover()
        closeWindow()
        replaceWindow(title: "About WandelBar") { AboutWandelBarView() }
    }

    func presentTextureManagement() {
        dismissPopover()
        closeWindow()
        replaceWindow(title: "Manage Textures") { TextureManagementView(model: model) }
    }

    func presentCommunityGallery() {
        dismissPopover()
        closeWindow()
        replaceWindow(title: "Community Presets") {
            CommunityGalleryView(onImport: { [weak self] url in
                guard let self else { try? FileManager.default.removeItem(at: url); return }
                self.importPackage(at: url, removeAfter: true)
            })
        }
    }

    func presentPresetSharing() {
        dismissPopover()
        closeWindow()
        model.beginPresetExportSelection()
        model.shareUsingCurrentWallpaper = false
        replaceWindow(title: "Share Presets") {
            PresetExportView(model: model, onChooseDestination: { [weak self] in self?.prepareSharing() },
                onCancel: { [weak self] in self?.closeWindow() },
                title: "Share to Discussions", explanation: "Choose presets and a preview background. Sharing files are prepared in a temporary folder.",
                actionTitle: "Prepare Share", showsSharingOptions: true)
        }
    }

    private func prepareSharing() {
        let presets = model.userPresets.filter { model.exportPresetIDs.contains($0.id) }
        startOperation(title: "Preparing Share", detail: "Rendering previews and packaging presets…") { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.model.prepareShare(presets: presets)
                guard !Task.isCancelled else { return }
                self.replaceWindow(title: "Ready to Share") { PresetShareResultView(result: result) }
            } catch {
                guard !Task.isCancelled else { return }
                self.showMessage(error.localizedDescription)
            }
        }
    }

    private var defaultExportName: String {
        let selected = model.userPresets.filter { model.exportPresetIDs.contains($0.id) }
        let base = selected.count == 1 ? selected[0].name : "WandelBar Presets"
        let safe = String(base.prefix(120)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(safe).wandelbar-presets"
    }

    private func startOperation(title: String, detail: String, preserveImport: Bool = false, work: @escaping @MainActor () async -> Void) {
        closeWindow(discardImport: !preserveImport)
        let id = UUID()
        operationID = id
        replaceWindow(title: title) {
            VStack(spacing: 16) {
                ProgressView()
                Text(detail)
                Button("Cancel") { [weak self] in self?.closeWindow() }
            }.padding(24).frame(width: 390)
        }
        operation = Task { [weak self] in
            await work()
            guard let self, self.operationID == id else { return }
            self.operation = nil
            self.operationID = nil
        }
    }

    private func begin(_ panel: NSOpenPanel, completion: @escaping (URL?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            MainActor.assumeIsolated { completion(response == .OK ? panel.url : nil) }
        }
    }

    /// Replacing the progress UI must not discard the newly prepared import token.
    private func replaceWindow<Content: View>(title: String, content: () -> Content) {
        window?.delegate = nil
        window?.close()
        let hosting = NSHostingController(rootView: content())
        hosting.sizingOptions = [.preferredContentSize]
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = title
        newWindow.styleMask = [.titled, .closable, .miniaturizable]
        newWindow.identifier = NSUserInterfaceItemIdentifier("WandelBar.dialog")
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()
        window = newWindow
        dockPresence.show(current: NSApp.activationPolicy()) { _ = NSApp.setActivationPolicy($0) }
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }

    private func closeWindow(discardImport: Bool = true) {
        operation?.cancel()
        operation = nil
        operationID = nil
        window?.delegate = nil
        window?.close()
        window = nil
        dockPresence.restore { _ = NSApp.setActivationPolicy($0) }
        if discardImport { model.cancelPresetImport() }
    }

    private func presentPackageMessage() {
        guard let message = model.presetPackageError ?? model.presetPackageCompletion else { return }
        model.clearPresetPackageMessage()
        showMessage(message)
    }

    private func showMessage(_ message: String) {
        replaceWindow(title: "WandelBar") {
            VStack(alignment: .leading, spacing: 16) {
                Text(message).textSelection(.enabled)
                HStack { Spacer(); Button("OK") { [weak self] in self?.closeWindow() } }
            }.padding(24).frame(width: 420)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        closeWindow()
    }
}
