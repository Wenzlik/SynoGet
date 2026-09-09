import SwiftUI

/// Post-login dashboard. Two stacked surfaces:
///
///   1. Hero card — NAS hostname + ambient status indicator in
///      the header. Primary slot dispatches on `heroState`:
///      `.transferring` shows the 44 pt focal speed + direction
///      arrow + live-pulse dot; `.taskIdle` shows the total task
///      count as the focal with a "Currently idle" subtitle;
///      `.empty` shows the calm "All caught up / No active
///      downloads" copy. Free-disk row is conditional on the
///      view-model placeholder (still nil pending the 0.5.1
///      SYNO.FileStation.Info wire-up).
///
///   2. Recently completed — up to five rows in an activity-feed
///      shape (icon disc, title, secondary metadata) inside a
///      single grouped material surface with hairline dividers
///      between rows. "See all →" accessory on the eyebrow header
///      drops the user into the Downloads tab with the `.finished`
///      filter pre-applied.
///
/// Add / Settings reachable via the toolbar `+` and gear. A
/// "Quick actions" section was prototyped in Phase 2 but
/// removed in 0.5.1 polish — three of the four planned actions
/// (Pause all / Resume all / Search) didn't have real backends
/// yet and disabled placeholders read as "coming soon" against
/// the rest of the modernised app. They return as the
/// DownloadTaskStore + bulk-action work lands.
///
/// Sits inside its own `NavigationStack` so sheets (Settings, Add
/// task) and pushed destinations stay scoped to this tab. Polls
/// its own `DashboardViewModel` for now; a shared
/// `DownloadTaskStore` is the next item up in 0.5.1.
struct DashboardView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var navigation: NavigationStore
    @StateObject private var viewModel: DashboardViewModel
    @State private var showingAddTask = false
    @State private var showingSettings = false
    /// Bumped after each user-initiated pull-to-refresh completes.
    /// Drives a `.sensoryFeedback(.success)` so the gesture has a
    /// tactile completion cue. Kept separate from the 5 s timer
    /// poll so background refreshes don't fire haptics.
    @State private var pullRefreshCount = 0

    init(session: SessionStore, store: DownloadTaskStore) {
        _viewModel = StateObject(
            wrappedValue: DashboardViewModel(
                store: store,
                hostname: Self.displayHostname(from: session.config)
            )
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.xl) {
                        heroCard
                            .redacted(reason: viewModel.hasLoadedOnce ? [] : .placeholder)
                            .animation(.easeInOut(duration: 0.25), value: viewModel.heroState)
                            .animation(.easeInOut(duration: 0.2), value: viewModel.isOnline)
                        // State-aware section ordering: when bytes are
                        // moving, the "Active now" feed leads and pushes the
                        // historical "Recently completed" section below it.
                        // When the NAS is idle, the active section drops out
                        // and Recently completed takes the top slot — the
                        // dashboard reads as a live activity overview while
                        // anything is in flight, and a calm historical feed
                        // otherwise.
                        if viewModel.hasActiveTransfers {
                            activeSection
                                .animation(.easeInOut(duration: 0.2), value: viewModel.activeTransfers.map(\.id))
                        }
                        recentSection
                            .redacted(reason: viewModel.hasLoadedOnce ? [] : .placeholder)
                            .animation(.easeInOut(duration: 0.2), value: viewModel.recentlyCompleted.map(\.id))
                    }
                    .padding(DSSpacing.lg)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.hasActiveTransfers)
                }
                .refreshable {
                    await viewModel.refresh()
                    pullRefreshCount &+= 1
                }
                .sensoryFeedback(.success, trigger: pullRefreshCount)
            }
            .navigationTitle("Dashboard")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddTask = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddTask) {
                AddTaskView(
                    onAddURI: { uri, destination in
                        await createTask(uri: uri, destination: destination)
                    },
                    onAddFile: { data, name, destination in
                        await createTask(fileData: data, filename: name, destination: destination)
                    }
                )
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .alert("Error", isPresented: .init(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .onChange(of: session.pendingMagnetLink) { _, newValue in
                if newValue != nil {
                    showingAddTask = true
                }
            }
            .onChange(of: session.pendingTorrentFile) { _, newValue in
                if newValue != nil {
                    showingAddTask = true
                }
            }
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        DSHeroCard {
            heroHeader
        } primary: {
            switch viewModel.heroState {
            case .transferring:
                activePrimary
            case .taskIdle:
                taskIdlePrimary
            case .empty:
                emptyPrimary
            }
        }
    }

    /// Hero header: drive glyph + hostname on the left, ambient
    /// status indicator on the right. Per the Phase-3 status
    /// hierarchy, Online is the ambient default (`DSStatusDot` +
    /// label) and only the exceptional Offline path bumps up to
    /// `DSStatusBadge`.
    private var heroHeader: some View {
        HStack(spacing: DSSpacing.sm) {
            DSIconTile(symbol: "externaldrive.connected.to.line.below")
            Text(viewModel.hostname)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            if viewModel.isOnline {
                HStack(spacing: 4) {
                    DSStatusDot(tint: .green)
                    Text("Online")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                DSStatusBadge("Offline", tint: .orange, systemImage: "circle.fill")
            }
        }
    }

    /// Empty hero (no tasks on the NAS at all). Pure T2 + T3
    /// typography, no T1 focal — a row of zeros would scream
    /// "broken", and an empty queue is supposed to feel calm.
    private var emptyPrimary: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text("All caught up")
                .font(.title.weight(.semibold))
            Text("No active downloads")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !idleMetricValues.isEmpty {
                DSMetricRow(values: idleMetricValues)
                    .padding(.top, DSSpacing.xs)
            }
        }
    }

    /// Task-idle hero: queue exists but nothing is moving right
    /// now (paused, hash-checking, waiting, finished). Shows the
    /// total task count as the T1 focal so the dashboard still
    /// has a glanceable number rather than a 0 KB/s that would
    /// read as a frozen-bug state. Subtitle communicates the
    /// idleness explicitly.
    private var taskIdlePrimary: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
                Text("\(viewModel.totalTaskCount)")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(viewModel.totalTaskCount == 1 ? "Task" : "Tasks")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text("Currently idle")
                .font(.headline.weight(.medium))
                .foregroundStyle(.primary)
            if !taskIdleMetricValues.isEmpty {
                DSMetricRow(values: taskIdleMetricValues)
            }
            if viewModel.failedCount > 0 {
                DSStatusBadge(
                    "\(viewModel.failedCount) failed",
                    tint: .red,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .padding(.top, DSSpacing.xs)
            }
        }
    }

    /// Active hero: T1 focal speed number with optional live-pulse
    /// dot, optional dual-throughput line (when both directions are
    /// flowing), T2 state title, T3 metric row. Failed count
    /// escalates to a `DSStatusBadge` (exceptional state) on its own
    /// row below.
    private var activePrimary: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            heroFocalRow
            // Dedicated dual-throughput line — only rendered when both
            // directions are moving. Single-direction case is already
            // covered by the T1 focal (arrow + rate), so showing the
            // zero side here would be visual noise. Torrent-heavy
            // users care about the upload side equally with download,
            // and burying it inside the metric row makes the upload
            // read as just another count fragment instead of a real
            // throughput.
            if heroShowsDualThroughput {
                heroDualThroughputRow
            }
            Text(heroStateLabel)
                .font(.headline.weight(.medium))
                .foregroundStyle(.primary)
            if !activeMetricValues.isEmpty {
                DSMetricRow(values: activeMetricValues)
            }
            if viewModel.failedCount > 0 {
                DSStatusBadge(
                    "\(viewModel.failedCount) failed",
                    tint: .red,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .padding(.top, DSSpacing.xs)
            }
        }
    }

    /// Dual-throughput line: `↓ X · ↑ Y`. Sits between the T1 focal
    /// and the T2 state label, slightly smaller than the metric row
    /// so it reads as throughput detail attached to the focal
    /// rather than a third independent metric.
    private var heroDualThroughputRow: some View {
        HStack(spacing: DSSpacing.sm) {
            Label(formattedRate(viewModel.totalDownloadSpeed), systemImage: "arrow.down")
                .labelStyle(.titleAndIcon)
            Text("·").foregroundStyle(.tertiary)
            Label(formattedRate(viewModel.totalUploadSpeed), systemImage: "arrow.up")
                .labelStyle(.titleAndIcon)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private var heroShowsDualThroughput: Bool {
        viewModel.totalDownloadSpeed > 0 && viewModel.totalUploadSpeed > 0
    }

    /// T1 focal: large rounded monospaced rate + direction arrow,
    /// with a pulsing status dot when bytes are actively moving.
    /// `.contentTransition(.numericText())` ticks the digits as the
    /// poll updates so the number reads as live without bouncing.
    private var heroFocalRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.sm) {
            Image(systemName: heroFocalDirectionSymbol)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(heroFocalTint)
            Text(formattedRate(heroFocalBytesPerSecond))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if heroIsActivelyTransferring {
                DSStatusDot(tint: heroFocalTint, pulsing: true)
                    .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Hero derived state

    /// Whether the NAS is currently moving bytes in either
    /// direction. Drives the pulsing focal dot.
    private var heroIsActivelyTransferring: Bool {
        viewModel.totalDownloadSpeed > 0 || viewModel.totalUploadSpeed > 0
    }

    /// Which direction "owns" the hero focal number. Download wins
    /// when present (it's the headline activity for a Download
    /// Station client); upload-only is the seeding-only case.
    /// Falls back to download (= 0) for the brief "1 active task
    /// hash-checking" window — viewModel.heroState has already
    /// shunted the everything-zero case to taskIdlePrimary or
    /// emptyPrimary, so this branch only runs when at least one
    /// direction is moving.
    private var heroFocalBytesPerSecond: Int64 {
        if viewModel.totalDownloadSpeed > 0 { return viewModel.totalDownloadSpeed }
        if viewModel.totalUploadSpeed > 0 { return viewModel.totalUploadSpeed }
        return viewModel.totalDownloadSpeed
    }

    private var heroFocalDirectionSymbol: String {
        viewModel.totalDownloadSpeed == 0 && viewModel.totalUploadSpeed > 0
            ? "arrow.up"
            : "arrow.down"
    }

    private var heroFocalTint: Color {
        viewModel.totalDownloadSpeed == 0 && viewModel.totalUploadSpeed > 0
            ? .accentColor
            : .blue
    }

    private var heroStateLabel: LocalizedStringKey {
        if viewModel.totalDownloadSpeed > 0 { return "Downloading" }
        if viewModel.totalUploadSpeed > 0 { return "Seeding" }
        return "Working…"
    }

    /// Tertiary metric line for the active hero. Pre-formats each
    /// fragment (count, free disk) and hands it to `DSMetricRow`
    /// which renders them with the shared subtle-dot separators.
    /// Dual-throughput moved to its own dedicated row above the
    /// state label — see `heroDualThroughputRow` — so the metric row
    /// can stay focused on counts/capacity instead of mixing units.
    private var activeMetricValues: [String] {
        var values: [String] = []
        if viewModel.activeCount > 0 {
            values.append(String(localized: "\(viewModel.activeCount) active"))
        }
        if let bytes = viewModel.freeDiskBytes {
            values.append(String(localized: "\(formattedSize(bytes)) free"))
        }
        return values
    }

    private var idleMetricValues: [String] {
        var values: [String] = []
        if let bytes = viewModel.freeDiskBytes {
            values.append(String(localized: "\(formattedSize(bytes)) free"))
        }
        return values
    }

    /// Tertiary metric line for the `.taskIdle` hero: how many of
    /// the tasks are paused vs. finished, plus free-disk when
    /// wired. Helps the user mental-model "what's the queue doing
    /// right now" beyond the single "X Tasks" focal number.
    private var taskIdleMetricValues: [String] {
        var values: [String] = []
        let pausedCount = viewModel.tasks.filter { TaskFilter.paused.matches($0) }.count
        let finishedCount = viewModel.tasks.filter { TaskFilter.finished.matches($0) }.count
        if pausedCount > 0 {
            values.append(String(localized: "\(pausedCount) paused"))
        }
        if finishedCount > 0 {
            values.append(String(localized: "\(finishedCount) finished"))
        }
        if let bytes = viewModel.freeDiskBytes {
            values.append(String(localized: "\(formattedSize(bytes)) free"))
        }
        return values
    }

    // MARK: - Active now

    /// Top section when transfers are in flight. Mirrors the
    /// Recently-completed surface (eyebrow header, grouped rows,
    /// "See all →" cross-tab nav) so the dashboard reads as one
    /// vocabulary regardless of which feed is dominant. Cap of
    /// three rows comes straight from the viewmodel — the rest of
    /// the queue lives behind the See-all jump into the Downloads
    /// tab with `.active` pre-applied.
    private var activeSection: some View {
        DSSection("Active now", style: .eyebrow) {
            DSGroupedRows(
                viewModel.activeTransfers,
                dividerInset: activityRowDividerInset
            ) { task in
                activeRow(for: task)
            }
        } accessory: {
            activeSeeAllAccessory
        }
    }

    /// "See all →" on the Active eyebrow header. Drops the user
    /// into Downloads with the `.active` filter pre-applied so the
    /// expanded view shows the same set the dashboard previewed
    /// (anything in flight) rather than a finished-only or
    /// downloading-only slice.
    @ViewBuilder
    private var activeSeeAllAccessory: some View {
        if viewModel.activeTransfers.count >= 3 {
            Button {
                navigation.showDownloads(filter: .active)
            } label: {
                HStack(spacing: 2) {
                    Text("See all")
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("See all active transfers")
        }
    }

    /// One row in the Active feed. Visually matches the activity
    /// row used by Recently-completed (icon disc + title +
    /// metadata) but appends a thin progress sliver so the row
    /// reads as live. Aligned past the 36 pt icon disc + md gap so
    /// the sliver visually anchors to the title text rather than
    /// running edge-to-edge.
    private func activeRow(for task: DownloadTask) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            DSActivityRow(
                title: ReleaseName(parsing: task.title).title,
                metadata: activeMetadataLine(for: task),
                iconSystemName: task.displayStatusTintRaw.statusSystemImage,
                iconTint: task.displayStatusTintRaw.tintColor
            )
            // Sliver tucked under the metadata, indented past the
            // icon disc so it traces the title column.
            if task.progress < 1 {
                DSProgressSliver(
                    value: task.progress,
                    tint: task.displayStatusTintRaw.tintColor
                )
                .padding(.leading, 48 + DSSpacing.md)
            }
        }
    }

    /// "↓ 5.2 MB/s · ETA 3m · 42%" style metadata for the Active
    /// row. Each fragment is conditional so seeding-only tasks
    /// (download speed 0, no ETA) still render cleanly with just
    /// "↑ X" and the status label.
    private func activeMetadataLine(for task: DownloadTask) -> String {
        var parts: [String] = []
        let down = task.additional?.transfer?.speedDownload.value ?? 0
        let up = task.additional?.transfer?.speedUpload.value ?? 0
        if down > 0 { parts.append("↓ \(formattedRate(down))") }
        if up > 0 { parts.append("↑ \(formattedRate(up))") }
        if let eta = etaString(for: task) { parts.append("ETA \(eta)") }
        // Percentage only useful while the file is still pulling
        // bytes — for a seeding-with-upload row the 100 % is implied.
        if task.progress < 1.0 {
            parts.append("\(Int(task.progress * 100))%")
        }
        if parts.isEmpty {
            // Nothing flowing but the task is in an active-state
            // bucket (hash_checking, waiting, …). Surface the
            // status label so the row isn't blank.
            parts.append(task.displayStatusLabel)
        }
        return parts.joined(separator: " · ")
    }

    /// Best-effort ETA for the Active row. Returns nil unless the
    /// task is actively pulling bytes with a known total size — a
    /// 0-byte/s ETA would be meaningless and a "—" placeholder
    /// noisier than no value at all.
    private func etaString(for task: DownloadTask) -> String? {
        guard task.status == .downloading,
              let down = task.additional?.transfer?.speedDownload.value,
              down > 0
        else { return nil }
        let remaining = max(0, task.size.value - (task.additional?.transfer?.sizeDownloaded.value ?? 0))
        let secs = TimeInterval(remaining) / TimeInterval(down)
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.day, .hour, .minute, .second]
        f.maximumUnitCount = 2
        return f.string(from: secs)
    }

    // MARK: - Recently completed

    private var recentSection: some View {
        DSSection("Recently completed", style: .eyebrow) {
            recentSectionContent
        } accessory: {
            seeAllAccessory
        }
    }

    /// Trailing accessory on the Recently-completed eyebrow. Tap
    /// flips to the Downloads tab and stages a `.finished` filter
    /// via `NavigationStore`, which `TaskListView` consumes and
    /// clears in its `.onChange` handler. Hidden during first
    /// load — the slot reads as "scroll to nothing" otherwise.
    @ViewBuilder
    private var seeAllAccessory: some View {
        if viewModel.hasLoadedOnce, !viewModel.recentlyCompleted.isEmpty {
            Button {
                navigation.showDownloads(filter: .finished)
            } label: {
                HStack(spacing: 2) {
                    Text("See all")
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("See all completed downloads")
        }
    }

    @ViewBuilder
    private var recentSectionContent: some View {
        if !viewModel.hasLoadedOnce {
            // First load — three skeleton rows inside the grouped
            // container so the section reads as "loading" rather
            // than "we checked and there's nothing". The .redacted
            // modifier on the outer recentSection then paints
            // these grey.
            DSGroupedRows(
                Array(repeating: DownloadTask.skeletonPlaceholder, count: 3),
                dividerInset: activityRowDividerInset
            ) { task in
                activityRow(for: task)
            }
        } else if viewModel.recentlyCompleted.isEmpty {
            DSCard(.secondary) {
                DSEmptyState(
                    title: "Nothing finished yet",
                    message: "Completed downloads will show up here.",
                    systemImage: "tray"
                )
            }
        } else {
            DSGroupedRows(
                viewModel.recentlyCompleted,
                dividerInset: activityRowDividerInset
            ) { task in
                activityRow(for: task)
            }
        }
    }

    /// Aligns the hairline divider inside `DSGroupedRows` past the
    /// 36-pt icon disc that `DSActivityRow` draws — so each row's
    /// divider starts under its title text, not under its icon.
    /// Sum: disc width + DSActivityRow's internal disc-to-text gap
    /// + DSGroupedRows' container leading padding.
    private var activityRowDividerInset: CGFloat {
        48 + DSSpacing.md + DSSpacing.lg
    }

    // MARK: - Helpers

    private var backgroundGradient: some View { DSBackground() }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formattedRate(_ bytesPerSecond: Int64) -> String {
        guard bytesPerSecond > 0 else { return "0 KB/s" }
        return "\(ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file))/s"
    }

    /// Best-effort display label for the configured NAS. Falls back
    /// to "NAS" if the host string is empty (shouldn't happen post-
    /// login but defends against an edge case where the config was
    /// cleared mid-flight). DSM model name (e.g. "DS920+") would
    /// require a `SYNO.FileStation.Info` call we haven't wired up.
    private static func displayHostname(from config: ServerConfig) -> String {
        let host = config.host.trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? "NAS" : host
    }

    private func createTask(uri: String, destination: String?) async {
        await viewModel.createTask(uri: uri, destination: destination)
    }

    private func createTask(fileData: Data, filename: String, destination: String?) async {
        await viewModel.createTask(fileData: fileData, filename: filename, destination: destination)
    }

    // MARK: - Activity row composition

    /// Maps a `DownloadTask` onto the domain-free `DSActivityRow`.
    /// Keeps DesignSystem/ free of app-model dependencies while
    /// centralising the dashboard's row formatting in one place
    /// (so Phase 3.2's visual pass can tune metadata wording
    /// without touching DSActivityRow).
    private func activityRow(for task: DownloadTask) -> some View {
        DSActivityRow(
            title: ReleaseName(parsing: task.title).title,
            metadata: metadataLine(for: task),
            iconSystemName: task.displayStatusTintRaw.statusSystemImage,
            iconTint: task.displayStatusTintRaw.tintColor
        )
    }

    /// "Completed 5m ago • 18.7 GB" when a completion timestamp is
    /// available; falls back to just the size string otherwise
    /// (older DSM builds occasionally omit `completed_time` for
    /// paused-at-100 % rows).
    private func metadataLine(for task: DownloadTask) -> String {
        let size = ByteCountFormatter.string(fromByteCount: task.size.value, countStyle: .file)
        guard let completed = completedDate(for: task) else { return size }
        let relative = Self.relativeFormatter.localizedString(for: completed, relativeTo: Date())
        return String(localized: "Completed \(relative) • \(size)")
    }

    private func completedDate(for task: DownloadTask) -> Date? {
        guard let raw = task.additional?.detail?.completedTime?.value, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(raw))
    }

    /// Single shared RelativeDateTimeFormatter — instantiation is
    /// non-trivial and the same instance is safe to reuse on the
    /// main actor where these rows render.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

private extension DownloadTask {
    /// Sentinel task used only to feed `ActivityFeedRow` placeholder
    /// rows behind a `.redacted(.placeholder)` modifier during the
    /// first dashboard load. Never decoded from the wire and never
    /// observed by users with the redaction off; the title text
    /// just needs enough length for the placeholder bar to look
    /// right.
    static var skeletonPlaceholder: DownloadTask {
        DownloadTask(
            id: "skeleton",
            title: "Loading recently completed download",
            size: 0,
            status: .finished,
            type: .bt,
            username: nil,
            additional: nil
        )
    }
}
