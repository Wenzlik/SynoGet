import SwiftUI

/// Neutral empty-state placeholder. Thin wrapper over
/// `ContentUnavailableView` that keeps title/message/image consistent
/// across screens (dashboard "no recent downloads", task list "no
/// downloads", etc.).
struct DSEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let systemImage: String

    init(
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        systemImage: String
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    var body: some View {
        ContentUnavailableView {
            DSIconTile(symbol: systemImage)
            Text(title).font(.title2.weight(.semibold))
        } description: {
            if let message {
                Text(message)
            }
        }
    }
}
