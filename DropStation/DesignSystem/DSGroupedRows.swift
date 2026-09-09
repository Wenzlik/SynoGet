import SwiftUI

/// Container that hosts N rows inside a single `.regularMaterial`
/// surface, separated by hairline dividers indented past the
/// caller-specified leading offset.
///
/// Replaces the per-row glass-card stacks that started showing up
/// in Phase 2. The Phase-3 hierarchy reserves `.glassEffect` for
/// the screen's primary surface (hero); secondary lists become
/// one calm grouped container with internal dividers — Linear /
/// Mail / Ivory shape, not a stack of floating cards.
///
/// Each row gets the container's standard horizontal padding
/// (`DSSpacing.lg`) and vertical `DSSpacing.sm`. Items are keyed
/// by their array position via `ForEach(id: \.offset)`, which
/// suits the small, append-only feeds the dashboard surfaces
/// today; callers that need diff-tracked animation on reorders
/// can swap to a keyed version in a follow-up.
struct DSGroupedRows<Item, RowContent: View>: View {
    private let items: [Item]
    private let dividerInset: CGFloat
    private let row: (Item) -> RowContent

    init(
        _ items: [Item],
        dividerInset: CGFloat = 0,
        @ViewBuilder row: @escaping (Item) -> RowContent
    ) {
        self.items = items
        self.dividerInset = dividerInset
        self.row = row
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Divider()
                        .padding(.leading, dividerInset)
                }
                row(item)
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.lg)
            }
        }
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(Color.dsSurfaceHairline, lineWidth: 0.5))
    }
}
