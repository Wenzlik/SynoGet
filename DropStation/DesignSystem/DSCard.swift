import SwiftUI

/// Surface style for `DSCard`. Top-level (not nested in DSCard)
/// so non-generic helpers can reference it without spelling out
/// the generic `Content` parameter. The `DSCard.Style` typealias
/// inside DSCard keeps the call-site spelling familiar.
enum DSCardStyle {
    case primary
    case secondary
    case flush
}

/// Generic card container with three surface styles. Phase-3
/// hierarchy:
///
///   - `.primary` — the single screen-defining surface (e.g. the
///     dashboard hero). Subtle Liquid Glass. Use sparingly, at
///     most one per screen.
///   - `.secondary` — everything else (activity containers, action
///     cells, metric blocks). `.regularMaterial` + half-point
///     hairline border. Calmer than glass-everywhere and ages
///     better.
///   - `.flush` — caller draws its own background; DSCard provides
///     only the padding and shape.
///
/// Default is `.secondary` so new call sites land on the
/// material-and-hairline surface by default. Existing surfaces
/// that want to keep their glass look pass `.primary` explicitly.
struct DSCard<Content: View>: View {
    typealias Style = DSCardStyle

    private let style: DSCardStyle
    private let content: Content

    init(_ style: DSCardStyle = .secondary, @ViewBuilder _ content: () -> Content) {
        self.style = style
        self.content = content()
    }

    var body: some View {
        content
            .padding(style == .primary ? DSSpacing.xl : DSSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SurfaceModifier(style: style))
    }
}

/// Applies the surface treatment per style. Kept as a private
/// `ViewModifier` so the switch lives in one place and the
/// `body` of DSCard stays readable.
private struct SurfaceModifier: ViewModifier {
    let style: DSCardStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: style == .primary ? DSRadius.hero : DSRadius.card, style: .continuous)
        switch style {
        case .primary:
            content.glassEffect(.regular, in: shape)
        case .secondary:
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.dsSurfaceHairline, lineWidth: 0.5))
        case .flush:
            content
        }
    }
}
