import SwiftUI

/// Inline row of pre-formatted metric strings separated by subtle
/// dot dividers — "3 active tasks · ↑ 3.2 MB/s · 1.2 TB free".
/// Designed for the hero card's tertiary metadata line and any
/// future surface that wants the same calm, dense data shape.
///
/// The caller pre-formats each value (so this component stays
/// domain-free and locale-free); DSMetricRow only enforces the
/// shared font, secondary tone, monospaced digits, and divider
/// styling.
struct DSMetricRow: View {
    private let values: [String]
    private let separator: String
    private let font: Font

    init(values: [String], separator: String = "·", font: Font = .subheadline) {
        self.values = values
        self.separator = separator
        self.font = font
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    if index > 0 {
                        Text(separator).foregroundStyle(.tertiary)
                    }
                    Text(value)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value)
                }
            }
        }
        .font(font)
        .foregroundStyle(.secondary)
        .monospacedDigit()

    }
}
