import SwiftUI

/// Error-state placeholder with optional retry action. Used as the
/// body of a screen when its primary data couldn't load. Composes
/// `ContentUnavailableView` so it inherits Apple's standard
/// presentation, with a Retry button bolted on when applicable.
struct DSErrorState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let retry: (() -> Void)?

    init(
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        retry: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.retry = retry
    }

    var body: some View {
        VStack(spacing: DSSpacing.md) {
            ContentUnavailableView {
                DSIconTile(symbol: "exclamationmark.triangle", tint: .orange)
                Text(title).font(.title2.weight(.semibold))
            } description: {
                if let message {
                    Text(message)
                }
            }
            if let retry {
                Button {
                    retry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(DSSpacing.lg)
    }
}
