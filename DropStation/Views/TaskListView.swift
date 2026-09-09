import SwiftUI
import UIKit

struct TaskListView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var navigation: NavigationStore
    @StateObject private var viewModel: TaskListViewModel
    @State private var showingAddTask = false
    @State private var showingSettings = false
    /// Task the user just swiped to delete; non-nil presents the
    /// keep-partial-files confirmation dialog.
    @State private var taskPendingDelete: DownloadTask?
    /// Bumped on every task action (swipe or context menu) to drive a
    /// confirming haptic via `.sensoryFeedback`.
    @State private var actionTick = 0

    init(session: SessionStore, store: DownloadTaskStore) {
        // 105 forwarding now lives on DownloadTaskStore — wired
        // once at app init — so this view model only carries the
        // view-local filter/sort/search state. `session` is kept
        // for the pendingMagnetLink observation downstream.
        _ = session
        _viewModel = StateObject(wrappedValue: TaskListViewModel(store: store))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient.ignoresSafeArea()
                List {
                    // Native List preserves swipe actions and refresh while shared
                    // rounded row surfaces establish the content rhythm.
                    Section {
                        ForEach(viewModel.filteredTasks) { task in
                            TaskRow(task: task)
                            // Tap target without the system disclosure
                            // chevron — a zero-opacity link behind the
                            // card keeps it a clean media-style tile.
                            .background {
                                NavigationLink(value: task) { EmptyView() }
                                    .opacity(0)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: DSSpacing.xs, leading: DSSpacing.lg, bottom: DSSpacing.xs, trailing: DSSpacing.lg))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    taskPendingDelete = task
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                if task.canPause {
                                    Button {
                                        actionTick += 1
                                        Task { await viewModel.pause(task) }
                                    } label: {
                                        Label("Pause", systemImage: "pause.fill")
                                    }
                                    .tint(.orange)
                                }
                                if task.canStop {
                                    Button {
                                        actionTick += 1
                                        Task { await viewModel.stop(task) }
                                    } label: {
                                        Label("Stop", systemImage: "stop.fill")
                                    }
                                    .tint(.gray)
                                }
                                if task.canResume {
                                    Button {
                                        actionTick += 1
                                        Task { await viewModel.resume(task) }
                                    } label: {
                                        Label("Resume", systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                            .contextMenu { rowMenu(for: task) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .top, spacing: 0) { filterChipBar }
                .refreshable { await viewModel.refresh() }
                .searchable(text: $viewModel.searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search downloads")
                .sensoryFeedback(.impact(weight: .light), trigger: actionTick)
            }
            .overlay {
                if viewModel.filteredTasks.isEmpty, !viewModel.isLoading {
                    DSEmptyState(
                        title: LocalizedStringKey(emptyStateTitle),
                        message: LocalizedStringKey(emptyStateMessage),
                        systemImage: emptyStateIcon
                    )
                }
            }
            .navigationTitle(navigationTitle)
            .navigationSubtitle(speedSubtitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
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
                        await viewModel.createTask(uri: uri, destination: destination)
                    },
                    onAddFile: { data, name, destination in
                        await viewModel.createTask(fileData: data, filename: name, destination: destination)
                    }
                )
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .navigationDestination(for: DownloadTask.self) { task in
                TaskDetailView(task: task, client: session.client)
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
            .onChange(of: navigation.downloadsFilterRequest) { _, request in
                // One-shot hint from a sibling tab (e.g. the
                // dashboard's "See all →" link landing on Finished).
                // Apply, then clear so the next user-driven filter
                // change isn't overwritten on a re-render.
                if let request {
                    viewModel.filter = request
                    navigation.downloadsFilterRequest = nil
                }
            }
            .alert("Error", isPresented: .init(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .confirmationDialog(
                "Delete this download?",
                isPresented: .init(
                    get: { taskPendingDelete != nil },
                    set: { if !$0 { taskPendingDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: taskPendingDelete
            ) { task in
                Button("Delete task and files", role: .destructive) {
                    Task { await viewModel.delete(task, keepPartialFiles: false) }
                }
                Button("Delete task only (keep partial files)") {
                    Task { await viewModel.delete(task, keepPartialFiles: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { task in
                Text(task.title)
            }
        }
    }

    private var backgroundGradient: some View { DSBackground() }

    // MARK: - Filter chips

    /// Quick-filter pills shown above the list. Always offers "All";
    /// the rest appear only when they have something in them, so the
    /// bar stays short and never shows an empty bucket.
    private var chipFilters: [TaskFilter] {
        var result: [TaskFilter] = [.all]
        for f in [TaskFilter.downloading, .seeding, .paused, .finished, .error]
        where viewModel.count(for: f) > 0 {
            result.append(f)
        }
        return result
    }

    private var filterChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(chipFilters) { f in
                    let selected = viewModel.filter == f
                    Button {
                        actionTick += 1
                        viewModel.filter = f
                    } label: {
                        HStack(spacing: 5) {
                            Text(f.label)
                            Text("\(viewModel.count(for: f))")
                                .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
                        )
                        .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
        }
    }

    // MARK: - Row context menu

    /// Long-press actions on a card: the same verbs as the swipe
    /// actions plus Copy link, so the common operations are reachable
    /// without remembering which swipe direction does what.
    @ViewBuilder
    private func rowMenu(for task: DownloadTask) -> some View {
        if task.canResume {
            Button {
                actionTick += 1
                Task { await viewModel.resume(task) }
            } label: { Label("Resume", systemImage: "play.fill") }
        }
        if task.canPause {
            Button {
                actionTick += 1
                Task { await viewModel.pause(task) }
            } label: { Label("Pause", systemImage: "pause.fill") }
        }
        if task.canStop {
            Button {
                actionTick += 1
                Task { await viewModel.stop(task) }
            } label: { Label("Stop", systemImage: "stop.fill") }
        }
        if let link = task.additional?.detail?.uri, !link.isEmpty {
            Button {
                UIPasteboard.general.string = link
                actionTick += 1
            } label: { Label("Copy link", systemImage: "doc.on.doc") }
        }
        Divider()
        Button(role: .destructive) {
            taskPendingDelete = task
        } label: { Label("Delete", systemImage: "trash") }
    }

    private var sortMenu: some View {
        Menu {
            // Two nested pickers: criterion, then direction. Tapping the
            // currently-selected criterion is a no-op (Picker swallows it),
            // so the direction is exposed as its own toggle below.
            Picker("Sort by", selection: $viewModel.sort) {
                ForEach(TaskSort.allCases) { s in
                    Label(s.label, systemImage: s.systemImage).tag(s)
                }
            }
            Divider()
            Picker("Direction", selection: $viewModel.sortDirection) {
                ForEach(TaskSortDirection.allCases) { d in
                    Label(d.label, systemImage: d.systemImage).tag(d)
                }
            }
        } label: {
            Image(systemName: viewModel.sortDirection == .ascending
                  ? "arrow.up.arrow.down.circle"
                  : "arrow.up.arrow.down.circle.fill")
        }
    }

    private var navigationTitle: String {
        // `.navigationTitle` takes the String overload here (the title
        // is computed, not a literal), which does NOT auto-localize —
        // that's why the title rendered as English "Downloads" inside
        // the Czech UI. Resolve through the catalog explicitly, and
        // compose the filtered variant from the localized base + the
        // (already-localized) filter label so we don't need a separate
        // "Downloads — %@" catalog entry.
        let base = String(localized: "Downloads")
        return viewModel.filter == .all ? base : "\(base) — \(viewModel.filter.label)"
    }

    private var speedSubtitle: String {
        let down = viewModel.totalDownloadSpeed
        let up = viewModel.totalUploadSpeed
        guard down > 0 || up > 0 else { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "↓ \(f.string(fromByteCount: down))/s   ↑ \(f.string(fromByteCount: up))/s"
    }

    private var hasSearch: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyStateTitle: String {
        if hasSearch { return String(localized: "No matches") }
        if viewModel.filter == .all {
            return String(localized: "No downloads")
        }
        let bucket = viewModel.filter.label.lowercased()
        return String(localized: "No \(bucket) downloads")
    }

    private var emptyStateIcon: String {
        hasSearch ? "magnifyingglass" : viewModel.filter.systemImage
    }

    private var emptyStateMessage: String {
        if hasSearch { return "No downloads match \"\(viewModel.searchText)\"." }
        return viewModel.filter == .all
            ? "Tap + to add a magnet, URL, or .torrent file."
            : "Switch filter or pull down to refresh."
    }
}

/// One download as a calm media-style card. Instead of a dense table
/// row of raw scene text, each task reads like an entry in a media
/// app:
///
///   - A rounded status tile (colour + glyph, pulsing while live) as
///     the leading anchor.
///   - A clean parsed title + year (`ReleaseName` turns
///     "Dune.2021.2160p.WEB-DL…-DeDo" into "Dune  2021").
///   - Up to three quality pills (4K / HDR / Atmos …) — the at-a-glance
///     "what kind of file is this".
///   - A quiet footer: status · optional live ↓ speed · size, with a
///     progress sliver only while the task is actively transferring.
///
/// The card sits on `.regularMaterial` with a hairline, spaced from
/// its neighbours by the list-row insets, so the screen breathes.
private struct TaskRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: DownloadTask

    private var release: ReleaseName { ReleaseName(parsing: task.title) }
    private var tint: Color { task.displayStatusTintRaw.tintColor }

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            statusTile
            VStack(alignment: .leading, spacing: 7) {
                titleLine
                if !release.tags.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(release.tags.prefix(3), id: \.self) { TagPill(text: $0) }
                    }
                }
                footerLine
                // Progress sliver only while actually pulling bytes —
                // a seeding task sits at 100 %, so a full-width bar on
                // every completed card was pure noise.
                if isDownloading {
                    DSProgressSliver(value: task.progress, tint: tint, height: 4)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DSSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .strokeBorder(Color.dsSurfaceHairline, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
    }

    /// Leading status tile — a soft tinted rounded square with the
    /// status glyph, pulsing while actively transferring. Reads like
    /// a small poster/app tile and gives the row a confident anchor.
    private var statusTile: some View {
        RoundedRectangle(cornerRadius: DSRadius.tile, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: 48, height: 48)
            .overlay(
                Image(systemName: task.displayStatusTintRaw.statusSystemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: isDownloading && !reduceMotion)
            )
            .accessibilityHidden(true)
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(release.title)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.tail)
            if let year = release.year {
                Text(year)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// Quiet footer: status word, an optional live ↓ speed, and the
    /// total size on the trailing edge. Percent/ETA are intentionally
    /// dropped from the card — the sliver carries progress; the card
    /// stays calm.
    private var footerLine: some View {
        HStack(spacing: 6) {
            Text(task.displayStatusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let speed = liveSpeed, speed > 0 {
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text("\(liveDirection) \(formattedSpeed(speed))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: DSSpacing.sm)
            Text(formattedSize(task.size.value))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// True for actively-transferring tasks — drives the pulsing tile,
    /// the inline ↓ speed, and the progress sliver. `.paused` is
    /// filtered out so paused transfers don't pulse.
    private var isLive: Bool {
        task.canPause && task.status != .paused
    }

    /// Strictly "bytes are arriving" — drives the pulse and the
    /// progress sliver. Narrower than `isLive` (which also covers
    /// seeding) so a seeding card neither pulses nor shows a bar.
    private var isDownloading: Bool {
        task.status == .downloading
    }

    private var liveDirection: String { task.status == .seeding ? "↑" : "↓" }

    private var liveSpeed: Int64? {
        guard isLive else { return nil }
        return task.status == .seeding
            ? task.additional?.transfer?.speedUpload.value
            : task.additional?.transfer?.speedDownload.value
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formattedSpeed(_ bytes: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))/s"
    }
}

/// Quiet quality chips keep semantic color reserved for task status.
private struct TagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(palette.fg)
            .background(Capsule(style: .continuous).fill(palette.bg))
    }

    private var palette: (fg: Color, bg: Color) {
        (Color.primary.opacity(0.7), Color.primary.opacity(0.06))
    }
}
