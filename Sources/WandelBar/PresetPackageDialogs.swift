import SwiftUI

struct PresetExportView: View {
    @ObservedObject var model: MenuBarPopoverModel
    let onChooseDestination: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Presets")
                .font(.title2.weight(.semibold))
            Text("Choose the presets to include. Custom textures are added automatically.")
                .foregroundStyle(.secondary)

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
                Button("Export…", action: onChooseDestination)
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
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Presets")
                .font(.title2.weight(.semibold))
            Text("The following presets will be added to My Presets.")
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(preview.presets) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.finalName)
                            if preset.wasRenamed {
                                Text("Renamed from \(preset.sourceName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 100, maxHeight: 260)

            if preview.embeddedTextureCount > 0 {
                Text("Includes \(preview.embeddedTextureCount) custom texture\(preview.embeddedTextureCount == 1 ? "" : "s").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Import", action: onImport)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
