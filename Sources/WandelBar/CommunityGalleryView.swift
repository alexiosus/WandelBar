import SwiftUI

/// Catalogue retrieval begins only when this explicitly opened gallery appears.
struct CommunityGalleryView: View {
    let onImport: (URL) -> Void
    private let service: CommunityCatalogService
    @State private var snapshot: CommunityCatalogSnapshot?
    @State private var query = ""
    @State private var selectedTag: String?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var downloadingID: String?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()

    init(onImport: @escaping (URL) -> Void, service: CommunityCatalogService = .init()) {
        self.onImport = onImport
        self.service = service
    }

    private var entries: [CommunityCatalogEntry] {
        (snapshot?.catalog.entries ?? []).filter { entry in
            (selectedTag == nil || entry.tags.contains(selectedTag!)) &&
            (query.isEmpty || ([entry.title, entry.author, entry.summary] + entry.tags).joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
    }
    private var tags: [String] { Array(Set(snapshot?.catalog.entries.flatMap(\.tags) ?? [])).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Community presets").font(.title2.bold())
                    Text("Curated from the official Preset Exchange").foregroundStyle(.secondary)
                }
                Spacer()
                Link("Preset Exchange ↗", destination: AppInformation.exchange)
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .help("Refresh catalogue").disabled(isLoading || downloadingID != nil)
            }
            Text("Opening this gallery contacts the official GitHub repository. Packages are downloaded only when you choose Preview import; you review them before adding anything to your library.")
                .font(.caption).foregroundStyle(.secondary)
            if let snapshot {
                Label(snapshot.status, systemImage: snapshot.isCached ? "clock.arrow.circlepath" : "checkmark.shield")
                    .font(.caption).foregroundStyle(snapshot.isCached ? Color.orange : Color.secondary)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            if isLoading {
                Spacer()
                ProgressView("Loading signed catalogue…").frame(maxWidth: .infinity)
                Spacer()
            } else if let snapshot, !snapshot.catalog.entries.isEmpty {
                HStack {
                    TextField("Search presets, creators and tags", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Picker("Tag", selection: $selectedTag) {
                        Text("All tags").tag(nil as String?)
                        ForEach(tags, id: \.self) { Text($0).tag(Optional($0)) }
                    }.frame(width: 170)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(entries) { entry in card(entry) }
                    }
                    if entries.isEmpty { Text("No presets match your search.").foregroundStyle(.secondary).padding(30) }
                }
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "person.2.crop.square.stack").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(snapshot == nil ? "Gallery unavailable" : "No curated presets yet").font(.headline)
                    Text("Explore or share a preset in Preset Exchange. Community submissions appear here after maintainer review.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 410)
                    Link("Open Preset Exchange", destination: AppInformation.exchange)
                }.frame(maxWidth: .infinity)
                Spacer()
            }
            if downloadingID != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Downloading and verifying package…").font(.caption)
                    Spacer()
                    Button("Cancel") { cancelOperation() }
                }
            }
        }
        .padding(24).frame(minWidth: 640, idealWidth: 720, minHeight: 440, idealHeight: 580)
        .onAppear { if snapshot == nil { refresh() } }
        .onDisappear { cancelOperation() }
    }

    private func card(_ entry: CommunityCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CommunityPreviewImage(entry: entry, service: service)
            HStack(alignment: .top) {
                Image(systemName: "menubar.rectangle").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).font(.headline)
                    Text("By \(entry.author)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(entry.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !entry.tags.isEmpty { Text(entry.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Link("Original post ↗", destination: entry.sourceURL).font(.caption)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
            Button("Preview import…") { download(entry) }.disabled(downloadingID != nil || isLoading)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func cancelOperation() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        isLoading = false
        downloadingID = nil
    }

    private func refresh() {
        cancelOperation()
        let id = operationID
        isLoading = true
        errorMessage = nil
        operation = Task { @MainActor in
            do {
                let result = try await service.load()
                guard !Task.isCancelled, operationID == id else { return }
                snapshot = result
            } catch {
                guard !Task.isCancelled, operationID == id else { return }
                errorMessage = error.localizedDescription
            }
            guard operationID == id else { return }
            isLoading = false
            operation = nil
        }
    }

    private func download(_ entry: CommunityCatalogEntry) {
        cancelOperation()
        let id = operationID
        downloadingID = entry.id
        errorMessage = nil
        operation = Task { @MainActor in
            do {
                let url = try await service.download(entry)
                guard !Task.isCancelled, operationID == id else { try? FileManager.default.removeItem(at: url); return }
                // Ownership transfers to the import flow, which removes the temporary file after preview.
                onImport(url)
            } catch {
                guard !Task.isCancelled, operationID == id else { return }
                errorMessage = error.localizedDescription
            }
            guard operationID == id else { return }
            downloadingID = nil
            operation = nil
        }
    }
}
