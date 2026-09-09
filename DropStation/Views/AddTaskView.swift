import SwiftUI
import UniformTypeIdentifiers

struct AddTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SessionStore

    @State private var mode: Mode = .file
    @State private var uri: String = ""
    @State private var pickedFile: PickedFile?
    @State private var pickedDestination: FileNode?
    @State private var isFileImporterPresented = false
    @State private var isFolderPickerPresented = false
    @State private var isSubmitting = false
    @State private var fileImportError: String?

    /// Callback for URI-based downloads. Destination is the path without leading slash
    /// (e.g. "Downloads/Movies"), or `nil` to use the server default.
    let onAddURI: (String, String?) async -> Void
    /// Callback for file-based downloads.
    let onAddFile: (Data, String, String?) async -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case uri
        case file
        var id: String { rawValue }

        /// User-facing picker label. Switch on the case rather than the
        /// rawValue so the literals are discoverable by Xcode's String
        /// Catalog auto-extractor.
        var label: String {
            switch self {
            case .uri:  return String(localized: "Link")
            case .file: return String(localized: "File")
            }
        }
    }

    struct PickedFile: Equatable {
        let name: String
        let data: Data
        let sizeDescription: String
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: DSSpacing.lg) {
                        DSIconTile(symbol: "tray.and.arrow.down")
                        Text("New download").font(.title2.weight(.semibold))
                    }
                    .padding(.vertical, DSSpacing.sm)
                    .listRowBackground(Color.clear)
                }
                Section {
                    Picker("Source", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                switch mode {
                case .uri:
                    Section("Download URI") {
                        TextField("magnet:?xt=… or https://…", text: $uri, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(3...10)

                        // PasteButton enables itself only when the system clipboard
                        // currently holds a URL (magnet:?…, http(s)://…) — iOS handles
                        // the detection without firing the "X pasted from Y" privacy
                        // banner that a manual UIPasteboard peek would trigger.
                        PasteButton(payloadType: URL.self) { urls in
                            if let url = urls.first {
                                uri = url.absoluteString
                            }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                    }
                case .file:
                    Section("Torrent file") {
                        if let picked = pickedFile {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(picked.name).lineLimit(1)
                                    Text(picked.sizeDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Change") {
                                    isFileImporterPresented = true
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Button {
                                isFileImporterPresented = true
                            } label: {
                                Label("Choose .torrent file…", systemImage: "folder")
                            }
                        }

                        if let fileImportError {
                            Text(fileImportError).foregroundStyle(.red).font(.caption)
                        }
                    }
                }

                Section("Destination") {
                    Button {
                        isFolderPickerPresented = true
                    } label: {
                        HStack {
                            Image(systemName: pickedDestination == nil ? "folder" : "folder.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                // Branch on the optional rather than using
                                // `?? "Default destination"`: the `??`
                                // expression is a `String`, which binds to
                                // the non-localizing `Text(_:)` overload and
                                // left the fallback rendering English in the
                                // Czech UI. A bare literal hits the
                                // LocalizedStringKey overload and resolves the
                                // catalog ("Výchozí cíl").
                                if let name = pickedDestination?.name {
                                    Text(name).foregroundStyle(.primary)
                                } else {
                                    Text("Default destination").foregroundStyle(.primary)
                                }
                                if let path = pickedDestination?.path {
                                    Text(path).font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("As configured in DSM")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    // The primary action — a prominent capsule, not a
                    // plain form-row button. The old default-styled row
                    // read as a disabled text field when nothing was
                    // picked; a bordered-prominent capsule looks
                    // unmistakably tappable when enabled and honestly
                    // dimmed when disabled.
                    Button {
                        Task { await submit() }
                    } label: {
                        Group {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("Add download").fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(!canSubmit || isSubmitting)
                    .listRowInsets(EdgeInsets(top: DSSpacing.sm, leading: DSSpacing.md, bottom: DSSpacing.sm, trailing: DSSpacing.md))
                    .listRowBackground(Color.clear)
                }
            }
            .dsFormCanvas()
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(DSRadius.hero)
            .navigationTitle("New download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let pending = session.pendingMagnetLink {
                    uri = pending
                    mode = .uri
                    session.pendingMagnetLink = nil
                }
                // A .torrent opened from Files / Safari / Mail —
                // preload it into the file slot and switch to File mode
                // so the sheet is one tap ("Add download") from done.
                if let torrent = session.pendingTorrentFile {
                    pickedFile = PickedFile(
                        name: torrent.name,
                        data: torrent.data,
                        sizeDescription: ByteCountFormatter.string(
                            fromByteCount: Int64(torrent.data.count),
                            countStyle: .file
                        )
                    )
                    mode = .file
                    session.pendingTorrentFile = nil
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: AddTaskView.allowedFileTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result)
            }
            .sheet(isPresented: $isFolderPickerPresented) {
                FolderPickerView { picked in
                    pickedDestination = picked
                }
            }
        }
    }

    private var canSubmit: Bool {
        switch mode {
        case .uri: return !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file: return pickedFile != nil
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let destination = pickedDestination?.destinationPath
        switch mode {
        case .uri:
            await onAddURI(uri.trimmingCharacters(in: .whitespacesAndNewlines), destination)
        case .file:
            guard let picked = pickedFile else { return }
            await onAddFile(picked.data, picked.name, destination)
        }
        dismiss()
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        fileImportError = nil
        switch result {
        case .failure(let error):
            fileImportError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // Files picked through .fileImporter return security-scoped URLs.
            // Without start/stop access the Data(contentsOf:) read fails with a permission error.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pickedFile = PickedFile(
                    name: url.lastPathComponent,
                    data: data,
                    sizeDescription: ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
                )
            } catch {
                fileImportError = error.localizedDescription
            }
        }
    }

    private static let allowedFileTypes: [UTType] = {
        var types: [UTType] = [.data]
        if let torrent = UTType(filenameExtension: "torrent") { types.insert(torrent, at: 0) }
        if let nzb = UTType(filenameExtension: "nzb") { types.append(nzb) }
        return types
    }()
}
