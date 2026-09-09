import SwiftUI

struct TaskDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewModel: TaskDetailViewModel
    @State private var showingTaskPriorityPicker = false
    /// File index whose priority picker is currently open (nil = closed).
    @State private var filePriorityFileIndex: Int?

    init(task: DownloadTask, client: SynologyAPIClient) {
        _viewModel = StateObject(wrappedValue: TaskDetailViewModel(task: task, client: client))
    }

    var body: some View {
        List {
            overviewSection
            actionsSection
            transferSection
            swarmSection
            if let files = viewModel.task.additional?.file?.filter({ $0.filename != nil }), !files.isEmpty {
                filesSection(files: files)
            }
            if let trackers = viewModel.task.additional?.tracker?.filter({ ($0.url ?? "").isEmpty == false }), !trackers.isEmpty {
                trackersSection(trackers: trackers)
            }
            sourceSection
        }
        .dsFormCanvas()
        .navigationTitle(viewModel.task.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.refresh() }
        .task {
            viewModel.startAutoRefresh()
            await viewModel.refresh()
        }
        .onDisappear { viewModel.stopAutoRefresh() }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .taskPriorityPicker(
            isPresented: $showingTaskPriorityPicker,
            currentPriority: currentTaskPriority
        ) { picked in
            Task { await viewModel.setTaskPriority(picked) }
        }
        .filePriorityPicker(
            isPresented: .init(
                get: { filePriorityFileIndex != nil },
                set: { if !$0 { filePriorityFileIndex = nil } }
            ),
            currentPriority: currentFilePriority,
            filename: currentFileFilename
        ) { picked in
            if let idx = filePriorityFileIndex {
                Task { await viewModel.setFilePriority(picked, fileIndex: idx) }
            }
        }
    }

    private var currentTaskPriority: TaskPriority? {
        guard let raw = viewModel.task.additional?.detail?.priority else { return nil }
        return TaskPriority(rawValue: raw.lowercased())
    }

    private var currentFilePriority: FilePriority? {
        guard let idx = filePriorityFileIndex,
              let files = viewModel.task.additional?.file,
              idx < files.count
        else { return nil }
        let file = files[idx]
        // Use the wanted-aware resolver so a previously-skipped file
        // re-opens the picker with `.skip` highlighted, even on the
        // DSM builds that leave the raw `priority` field unchanged
        // after a skip toggle.
        return FilePriority.from(rawPriority: file.priority, wanted: file.wanted)
    }

    private var currentFileFilename: String? {
        guard let idx = filePriorityFileIndex,
              let files = viewModel.task.additional?.file,
              idx < files.count
        else { return nil }
        return files[idx].filename
    }

    // MARK: - Sections

    /// Progress hero — the detail screen's primary surface. Leads
    /// with the status glyph + title, then a large monospaced
    /// percentage, the progress sliver, and a live ↓/↑ throughput
    /// line while bytes are moving. Speeds live here (not as two
    /// more "—" rows buried in the Transfer list) so the screen
    /// answers "what's it doing right now" at the top.
    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                HStack(spacing: DSSpacing.sm) {
                    Image(systemName: viewModel.task.displayStatusTintRaw.statusSystemImage)
                        .foregroundStyle(viewModel.task.displayStatusTintRaw.tintColor)
                        .symbolEffect(.pulse, options: .repeating, isActive: isLive && !reduceMotion)
                    Text(viewModel.task.title).font(.headline)
                }
                HStack(alignment: .firstTextBaseline) {
                    statusInline
                    Spacer()
                    if !viewModel.task.isAtCompletion {
                        Text("\(Int(viewModel.task.progress * 100))%")
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                    }
                }
                if !viewModel.task.isAtCompletion {
                    DSProgressSliver(
                        value: viewModel.task.progress,
                        tint: viewModel.task.displayStatusTintRaw.tintColor
                    )
                }
                heroThroughput
            }
            .padding(DSSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: DSRadius.hero))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    /// True while the task is actively transferring in either
    /// direction — drives the pulsing hero glyph and the live
    /// throughput line.
    private var isLive: Bool {
        guard let t = viewModel.task.additional?.transfer else { return false }
        return t.speedDownload.value > 0 || t.speedUpload.value > 0
    }

    /// `↓ 5.2 MB/s · ↑ 1.1 MB/s` line shown in the hero only while
    /// something is flowing. Each side is conditional so a
    /// download-only or seed-only task shows just the one arrow.
    @ViewBuilder
    private var heroThroughput: some View {
        if let t = viewModel.task.additional?.transfer {
            let down = t.speedDownload.value
            let up = t.speedUpload.value
            if down > 0 || up > 0 {
                HStack(spacing: DSSpacing.sm) {
                    if down > 0 {
                        Label(Self.bytesPerSecond(down), systemImage: "arrow.down")
                            .foregroundStyle(.primary)
                    }
                    if down > 0 && up > 0 {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    if up > 0 {
                        Label(Self.bytesPerSecond(up), systemImage: "arrow.up")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .labelStyle(.titleAndIcon)
            }
        }
    }

    /// On-screen primary actions (Pause / Resume / Stop) — the
    /// common operations were previously buried in the toolbar "…"
    /// menu, which is poor discoverability for the verbs a user
    /// reaches for most. Rendered as capsule buttons right under the
    /// hero: Resume is prominent (accent), Pause/Stop are bordered.
    @ViewBuilder
    private var actionsSection: some View {
        if viewModel.task.canResume || viewModel.task.canPause || viewModel.task.canStop {
            Section {
                HStack(spacing: DSSpacing.sm) {
                    if viewModel.task.canResume {
                        Button {
                            Task { await viewModel.resume() }
                        } label: {
                            Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    if viewModel.task.canPause {
                        Button {
                            Task { await viewModel.pause() }
                        } label: {
                            Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    if viewModel.task.canStop {
                        Button {
                            Task { await viewModel.stop() }
                        } label: {
                            Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .listRowInsets(EdgeInsets(top: DSSpacing.xs, leading: DSSpacing.md, bottom: DSSpacing.xs, trailing: DSSpacing.md))
                .listRowBackground(Color.clear)
            }
        }
    }

    /// Phase-3 ambient status pattern — same DSStatusDot + label
    /// the Downloads list now uses for every row. Replaces the
    /// previous glass-capsule statusPill so the detail screen
    /// speaks the app-wide visual language. `displayStatusLabel`
    /// still folds paused-at-100 % into "Ended" for parity with
    /// the list.
    private var statusInline: some View {
        HStack(spacing: 4) {
            DSStatusDot(tint: viewModel.task.displayStatusTintRaw.tintColor)
            Text(viewModel.task.displayStatusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// Transfer volumes — the "how much" of the task. Live speeds
    /// moved up to the hero; the swarm counters moved to their own
    /// section, so this list stays a tight cluster of size /
    /// downloaded / uploaded / ratio / ETA instead of a flat
    /// nine-row data dump mixing volumes, speeds, and peer counts.
    private var transferSection: some View {
        Section("Transfer") {
            row("Size", value: Self.bytes(viewModel.task.size.value))
            if let t = viewModel.task.additional?.transfer {
                let down = t.sizeDownloaded.value
                let up = t.sizeUploaded.value
                let sd = t.speedDownload.value
                row("Downloaded", value: Self.bytes(down))
                row("Uploaded", value: Self.bytes(up))
                if down > 0 {
                    let ratio = Double(up) / Double(down)
                    row("Ratio", value: String(format: "%.2f", ratio))
                }
                if viewModel.task.status == .downloading, sd > 0 {
                    let remaining = max(0, viewModel.task.size.value - down)
                    let secs = Double(remaining) / Double(sd)
                    row("ETA", value: Self.duration(secs))
                }
            }
        }
    }

    /// Swarm counters (peers / seeders / leechers) — the "who" of a
    /// BT task. Its own grouped section so the network picture reads
    /// as a unit and doesn't dilute the Transfer volumes. Absent for
    /// non-BT tasks that carry no peer detail.
    @ViewBuilder
    private var swarmSection: some View {
        if let d = viewModel.task.additional?.detail,
           d.totalPeers != nil || d.connectedSeeders != nil || d.connectedLeechers != nil {
            Section("Swarm") {
                if let peers = d.totalPeers { row("Peers", value: "\(peers.value) total") }
                if let s = d.connectedSeeders { row("Seeders", value: "\(s.value) connected") }
                if let l = d.connectedLeechers { row("Leechers", value: "\(l.value) connected") }
            }
        }
    }

    private func filesSection(files: [DownloadTask.Additional.TorrentFile]) -> some View {
        Section("Files (\(files.count))") {
            // We need the index alongside each file for the per-file priority
            // API. Synology returns files in stable torrent-order so positional
            // index in this array matches the BT info dictionary's order.
            ForEach(Array(files.enumerated()), id: \.element.id) { idx, file in
                Button {
                    filePriorityFileIndex = idx
                } label: {
                    fileRow(file: file)
                }
            }
        }
    }

    /// One row in the torrent file list. Renders one of three
    /// visual treatments so the user can scan state at a glance
    /// rather than parsing the priority dropdown of every row:
    ///
    ///   - **Skipped** — the file's `wanted` flag is off (or DSM
    ///     echoed `priority="skip"`). Row is faded to ~55 % opacity,
    ///     a `⊘ Skipped` chip replaces the priority label, no
    ///     progress sliver. The disabled look matches what the file
    ///     is actually doing on the server (nothing).
    ///   - **Completed** — progress hit 1.0 and the file is wanted.
    ///     Muted `✓` accessory replaces the priority text, no
    ///     progress sliver (a 100 %-filled bar is redundant
    ///     chrome). The whole row stays at full opacity so it reads
    ///     as a present, settled state.
    ///   - **Downloading** — progress < 1.0 and wanted. Keeps the
    ///     thin progress sliver and surfaces the priority label as
    ///     quiet `.caption` / `.tertiary` text so the picker entry
    ///     point is discoverable without dominating the row.
    ///
    /// Priority hierarchy stays subtle even in the downloading
    /// case: the picker is reached by tapping anywhere in the row,
    /// so the trailing label is information-density, not a button
    /// affordance — a big "Low / Normal / High" pill would compete
    /// with the filename, which is the actual identity of the row.
    private func fileRow(file: DownloadTask.Additional.TorrentFile) -> some View {
        let priority = FilePriority.from(rawPriority: file.priority, wanted: file.wanted)
        let down = file.sizeDownloaded?.value ?? 0
        let total = file.size?.value ?? 0
        let isComplete = priority != .skip && total > 0 && file.progress >= 1.0
        let isSkipped = priority == .skip
        return VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(file.filename ?? "(unnamed)")
                .lineLimit(2)
                .truncationMode(.middle)
                .font(.subheadline)
                .foregroundStyle(.primary)
            HStack {
                Text("\(Self.bytes(down)) / \(Self.bytes(total))")
                    .monospacedDigit()
                Spacer()
                fileStateAccessory(priority: priority, isComplete: isComplete)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Progress sliver only for files that are still pulling
            // bytes and aren't skipped — completed and skipped rows
            // have no progress to communicate.
            if !isSkipped && !isComplete && total > 0 {
                DSProgressSliver(value: file.progress, tint: .accentColor)
            }
        }
        .padding(.vertical, 2)
        // The whole row dims for skipped files so the disabled
        // intent reads immediately. Opacity instead of a separate
        // colour palette keeps the row picker-discoverable (the
        // chevron is still visible, just quieter).
        .opacity(isSkipped ? 0.55 : 1.0)
    }

    /// Trailing state chip used by `fileRow`. Skipped/completed
    /// render a glyph + matching label; downloading falls back to
    /// the priority text so the picker entry point stays
    /// discoverable. Kept as `@ViewBuilder` rather than returning a
    /// `Text` so the icon-bearing variants can use SF Symbols
    /// directly.
    @ViewBuilder
    private func fileStateAccessory(priority: FilePriority, isComplete: Bool) -> some View {
        if priority == .skip {
            Label("Skipped", systemImage: "nosign")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
        } else if isComplete {
            Image(systemName: "checkmark")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Completed")
        } else {
            Text(priority.label)
                .foregroundStyle(.tertiary)
        }
    }

    private func trackersSection(trackers: [DownloadTask.Additional.Tracker]) -> some View {
        Section("Trackers (\(trackers.count))") {
            ForEach(trackers) { tracker in
                VStack(alignment: .leading, spacing: 4) {
                    Text(tracker.url ?? "").lineLimit(2).font(.subheadline.monospaced())
                    HStack {
                        if let s = tracker.status { Text(s) }
                        Spacer()
                        if let seeds = tracker.seeds, let peers = tracker.peers {
                            Text("\(seeds.value) seeds · \(peers.value) peers")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var sourceSection: some View {
        Section("Source") {
            row("Type", value: viewModel.task.type.rawValue.uppercased())
            if let owner = viewModel.task.username, !owner.isEmpty {
                row("Owner", value: owner)
            }
            if let d = viewModel.task.additional?.detail {
                if let dest = d.destination { row("Destination", value: dest) }
                if let prio = d.priority {
                    priorityRow(rawPriority: prio)
                }
                if let t = d.createTime {
                    let date = Date(timeIntervalSince1970: TimeInterval(t.value))
                    row("Created", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let uri = d.uri, !uri.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("URI").font(.caption).foregroundStyle(.secondary)
                        Text(uri).font(.footnote.monospaced()).lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Priority row — tappable for BT torrents (Synology's DS2 set-priority
    /// endpoint is BT-only). For HTTP/FTP/NZB it renders as plain text so the
    /// user doesn't tap into a dead-end picker.
    @ViewBuilder
    private func priorityRow(rawPriority: String) -> some View {
        let isBT = viewModel.task.type == .bt || viewModel.task.type == .magnet
        if isBT {
            Button {
                showingTaskPriorityPicker = true
            } label: {
                HStack {
                    Text("Priority").foregroundStyle(.primary)
                    Spacer()
                    Text(rawPriority.capitalized)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            row("Priority", value: rawPriority.capitalized)
        }
    }

    private func row(_ label: LocalizedStringKey, value: String) -> some View {
        LabeledContent(label) {
            Text(value).monospacedDigit().contentTransition(.numericText())
        }
    }

    // MARK: - Formatters

    private static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    private static func bytesPerSecond(_ n: Int64) -> String {
        n > 0 ? "\(bytes(n))/s" : "—"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.maximumUnitCount = 2
        return f.string(from: seconds) ?? "—"
    }
}
