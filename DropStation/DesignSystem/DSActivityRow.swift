import SwiftUI

/// One row in an activity feed: leading icon disc, dominant title,
/// secondary metadata line. Designed to sit inside a single
/// outer container (one `DSCard.secondary` wrapping N rows
/// separated by hairlines) rather than as a card-per-row stack —
/// modern activity feed, not a Settings list.
///
/// Domain-free: takes pre-formatted strings + icon, doesn't reach
/// into `DownloadTask` or any app model. Phase-3.3's activity-feed
/// adoption will compose these from a small caller-side helper;
/// future surfaces (notifications, search results, server activity
/// feed) can reuse the same component without refactoring.
///
/// Visual hierarchy:
///
///   - Icon tile — 48 pt quiet rounded square tinted by the
///     caller's status colour, monochrome glyph inside.
///   - Title — `.subheadline.weight(.medium)`, primary, up to two
///     lines, middle-truncation so the prefix and format suffix
///     of long torrent names both stay visible.
///   - Metadata — `.caption.monospacedDigit()`, secondary,
///     single line. The caller formats it ("Completed 5m ago · 18.7 GB").
///
/// Tap handling is intentionally not built in — callers attach an
/// `.onTapGesture` or wrap in a NavigationLink as needed. Phase
/// 3.3 will revisit when wiring tap-to-detail.
struct DSActivityRow: View {
    let title: String
    let metadata: String?
    let iconSystemName: String
    let iconTint: Color

    init(
        title: String,
        metadata: String? = nil,
        iconSystemName: String,
        iconTint: Color = .accentColor
    ) {
        self.title = title
        self.metadata = metadata
        self.iconSystemName = iconSystemName
        self.iconTint = iconTint
    }

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            iconDisc
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let metadata {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// A quiet status tile leaves the primary glass to the hero.
    private var iconDisc: some View {
        DSIconTile(symbol: iconSystemName, tint: iconTint)
            .frame(width: 48, height: 48)
    }
}
