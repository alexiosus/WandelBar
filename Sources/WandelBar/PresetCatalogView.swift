import SwiftUI

struct PresetCatalogView: View {
    @ObservedObject var model: MenuBarPopoverModel
    let dismiss: () -> Void

    @State private var presetName = ""
    @State private var presetDialogError: String?
    @State private var showingSavePreset = false
    @State private var showingRenamePreset = false
    @State private var showingDeletePreset = false
    @State private var showingReplacePreset = false
    @State private var renameTarget: EffectPreset?
    @State private var deleteTarget: EffectPreset?
    @State private var replacementTarget: EffectPreset?
    @State private var operationError: String?

    private let layout = PresetCatalogLayout(containerWidth: 360)

    private var columns: [GridItem] {
        [
            GridItem(.fixed(layout.cardWidth), spacing: layout.columnSpacing),
            GridItem(.fixed(layout.cardWidth), spacing: layout.columnSpacing)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            catalogHeader

            Divider()

            if model.isUsingPresetPreviewFallback {
                Label(
                    "Current wallpaper unavailable — showing sample background",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)

                Divider()
            }

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(model.presetCatalogSections) { section in
                        Section {
                            if section.id == "user" {
                                SaveCurrentPresetCard(
                                    previewSize: layout.previewSize,
                                    action: beginSavingCurrentPreset
                                )
                            }

                            ForEach(section.presets) { preset in
                                PresetCatalogCard(
                                    preset: preset,
                                    preview: model.presetPreviews[preset.id],
                                    placeholder: model.presetPreviewPlaceholder,
                                    isSelected: model.activePreset?.id == preset.id,
                                    isLoading: model.isPreparingPresetPreviews,
                                    previewSize: layout.previewSize,
                                    onRename: preset.kind == .user ? {
                                        beginRenaming(preset)
                                    } : nil,
                                    onDelete: preset.kind == .user ? {
                                        beginDeleting(preset)
                                    } : nil
                                ) {
                                    model.applyPreset(id: preset.id)
                                }
                            }
                        } header: {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                        }
                    }
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task(id: model.presetRevision) {
            await model.preparePresetPreviews()
        }
        .alert("Save Preset", isPresented: $showingSavePreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { @MainActor in
                    await saveCurrentPreset()
                }
            }
        } message: {
            Text(presetDialogError ?? "Save the current effect settings as a reusable preset.")
        }
        .alert("Replace Preset?", isPresented: $showingReplacePreset) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", action: replacePreset)
        } message: {
            Text("Replace “\(replacementTarget?.name ?? "this preset")” with the current settings?")
        }
        .alert("Rename Preset", isPresented: $showingRenamePreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Rename", action: renamePreset)
        } message: {
            Text(presetDialogError ?? "Enter a new name for this preset.")
        }
        .alert("Delete Preset?", isPresented: $showingDeletePreset) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: deletePreset)
        } message: {
            Text("Delete “\(deleteTarget?.name ?? "this preset")”? Applied settings will not change.")
        }
        .alert("Preset Error", isPresented: operationErrorPresented) {
            Button("OK") { operationError = nil }
        } message: {
            Text(operationError ?? "The preset could not be updated.")
        }
    }

    private var catalogHeader: some View {
        ZStack {
            Text("Presets")
                .font(.headline)

            HStack {
                Button(action: dismiss) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(action: model.requestPresetImport) {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel("Import Presets")
                .help("Import Presets")

                Button(action: model.requestPresetExport) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(model.userPresets.isEmpty)
                .accessibilityLabel("Export Presets")
                .help("Export Presets")
            }
            .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private var operationErrorPresented: Binding<Bool> {
        Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )
    }

    private func beginSavingCurrentPreset() {
        presetName = ""
        presetDialogError = nil
        showingSavePreset = true
    }

    private func saveCurrentPreset() async {
        do {
            try await model.saveCurrentPresetWithPreparedPreview(name: presetName)
            presetDialogError = nil
        } catch EffectPresetStore.StoreError.duplicateName(let name) {
            if let existing = model.userPresets.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                replacementTarget = existing
                Task { @MainActor in
                    await Task.yield()
                    showingReplacePreset = true
                }
            } else {
                retrySave(with: "“\(name)” is a built-in preset and cannot be replaced. Choose another name.")
            }
        } catch {
            retrySave(with: error.localizedDescription)
        }
    }

    private func replacePreset() {
        guard let replacementTarget else { return }
        do {
            try model.replacePreset(id: replacementTarget.id)
            self.replacementTarget = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func beginRenaming(_ preset: EffectPreset) {
        renameTarget = preset
        presetName = preset.name
        presetDialogError = nil
        showingRenamePreset = true
    }

    private func renamePreset() {
        guard let renameTarget else { return }
        do {
            try model.renamePreset(id: renameTarget.id, to: presetName)
            self.renameTarget = nil
            presetDialogError = nil
        } catch {
            presetDialogError = error.localizedDescription
            Task { @MainActor in
                await Task.yield()
                showingRenamePreset = true
            }
        }
    }

    private func beginDeleting(_ preset: EffectPreset) {
        deleteTarget = preset
        showingDeletePreset = true
    }

    private func deletePreset() {
        guard let deleteTarget else { return }
        do {
            try model.deletePreset(id: deleteTarget.id)
            self.deleteTarget = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func retrySave(with message: String) {
        presetDialogError = message
        Task { @MainActor in
            await Task.yield()
            showingSavePreset = true
        }
    }
}

private struct SaveCurrentPresetCard: View {
    let previewSize: CGSize
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                Text("Save Current")
                    .font(.caption.weight(.medium))
            }
            .frame(width: previewSize.width, height: previewSize.height + 30)
            .background(Color.primary.opacity(isHovered ? 0.09 : 0.045))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(isHovered ? 0.24 : 0.13),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .accessibilityHint("Saves the current settings as a new preset")
        .help("Save Current Settings as Preset")
    }
}

private struct PresetCatalogCard: View {
    let preset: EffectPreset
    let preview: NSImage?
    let placeholder: NSImage?
    let isSelected: Bool
    let isLoading: Bool
    let previewSize: CGSize
    let onRename: (() -> Void)?
    let onDelete: (() -> Void)?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 0) {
                    previewContent
                        .frame(width: previewSize.width, height: previewSize.height)
                        .clipped()

                    HStack(spacing: 5) {
                        Text(preset.name)
                            .font(.caption.weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 2)

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(width: previewSize.width, height: 30)
                }
                .frame(width: previewSize.width)
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(isHovered ? 0.18 : 0.08),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(preset.name)
            .accessibilityValue(isSelected ? "Selected" : "")
            .accessibilityHint("Applies this preset")

            if onRename != nil || onDelete != nil {
                HStack {
                    if let onRename {
                        cardActionButton(
                            systemName: "pencil",
                            help: "Rename \(preset.name)",
                            action: onRename
                        )
                    }

                    Spacer()

                    if let onDelete {
                        cardActionButton(
                            systemName: "xmark",
                            help: "Delete \(preset.name)",
                            foregroundStyle: .red,
                            action: onDelete
                        )
                    }
                }
                .padding(6)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .animation(.easeOut(duration: 0.12), value: isHovered)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .help(preset.name)
    }

    private func cardActionButton(
        systemName: String,
        help: String,
        foregroundStyle: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(foregroundStyle)
                .frame(width: 23, height: 23)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var previewContent: some View {
        if let preview {
            Image(nsImage: preview)
                .resizable()
                .scaledToFill()
        } else if let placeholder {
            Image(nsImage: placeholder)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle()
                    .fill(Color.primary.opacity(isLoading ? 0.07 : 0.045))

                if !isLoading {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var cardBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.12)
        }
        return Color.primary.opacity(isHovered ? 0.09 : 0.055)
    }
}
