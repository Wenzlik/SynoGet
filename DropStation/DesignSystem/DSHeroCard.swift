import SwiftUI

/// Dominant top card used as a screen's "above the fold" focal
/// point. Two-slot layout: a header slot for context / status (e.g.
/// hostname + Online badge), and a primary slot for the large
/// content (numbers, idle copy, hero illustration). Generic — the
/// dashboard's NAS status hero is the first user, but any screen
/// that wants a single dominant card on top can reuse this.
struct DSHeroCard<Header: View, Primary: View>: View {
    private let header: Header
    private let primary: Primary

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder primary: () -> Primary
    ) {
        self.header = header()
        self.primary = primary()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xl) {
            header
            Divider().overlay(Color.dsSurfaceHairline)
            primary
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: DSRadius.hero, style: .continuous)
        )
    }
}
