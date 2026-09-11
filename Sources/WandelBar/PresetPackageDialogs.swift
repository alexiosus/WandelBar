import SwiftUI

struct PresetExportView: View {
    @ObservedObject var model: MenuBarPopoverModel
    let onChooseDestination: () -> Void
    let onCancel: () -> Void
    var title = "Export Presets"
    var explanation = "Choose the presets to include. Custom textures are added automatically."
    var actionTitle = "Export…"
    var showsSharingOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsSharingOptions {
                Toggle("Use current wallpaper in previews", isOn: $model.shareUsingCurrentWallpaper)
                Text(model.shareUsingCurrentWallpaper
                    ? "Your current wallpaper will be visible in the shared preview images. Windows and desktop icons are never captured."
                    : "Previews use the built-in sample background.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.userPresets) { preset in
                        Toggle(preset.name, isOn: Binding(
                            get: { model.exportPresetIDs.contains(preset.id) },
                            set: { model.setPresetSelectedForExport(preset.id, selected: $0) }
                        ))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 280)

            HStack {
                Button("Select All") {
                    for preset in model.userPresets {
                        model.setPresetSelectedForExport(preset.id, selected: true)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(actionTitle, action: onChooseDestination)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.exportPresetIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct PresetImportPreviewView: View {
    let preview: PresetPackageImportPreview
    let onImportSelection: (Set<String>) -> Void
    let onCancel: () -> Void
    @State private var selected: Set<String>

    init(preview: PresetPackageImportPreview, onImportSelection: @escaping (Set<String>) -> Void, onCancel: @escaping () -> Void) {
        self.preview = preview
        self.onImportSelection = onImportSelection
        self.onCancel = onCancel
        _selected = State(initialValue: Set(preview.presets.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Presets").font(.title2.weight(.semibold))
            Text("Choose what to add. Nothing is applied automatically.").foregroundStyle(.secondary)
            Text("Previews use a sample background.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(preview.presets) { preset in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle(preset.finalName, isOn: Binding(
                                get: { selected.contains(preset.id) },
                                set: { if $0 { selected.insert(preset.id) } else { selected.remove(preset.id) } }
                            )).labelsHidden().accessibilityLabel(preset.finalName)
                            VStack(alignment: .leading, spacing: 5) {
                                if let data = preset.previewPNG, let image = NSImage(data: data) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 104).clipped()
                                }
                                Text(preset.finalName).fontWeight(.medium)
                                if preset.wasRenamed {
                                    Text("Renamed from \(preset.sourceName)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }.frame(minHeight: 160, maxHeight: 430)
            HStack {
                Button(selected.count == preview.presets.count ? "Deselect All" : "Select All") {
                    selected = selected.count == preview.presets.count ? [] : Set(preview.presets.map(\.id))
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Import \(selected.count)") { onImportSelection(selected) }
                    .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            }
        }.padding(20).frame(width: 480)
    }
}
