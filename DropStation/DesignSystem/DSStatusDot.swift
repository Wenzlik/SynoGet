import SwiftUI

/// Small filled status indicator — the ambient-state default across
/// the design system (Online, Active, Paused, Completed, all the
/// non-exceptional states). For exceptional states that demand
/// attention (Offline, Error, Reconnecting, Beta) use
/// `DSStatusBadge` instead.
///
/// Optional `pulsing` flag runs a native `.symbolEffect(.pulse)`,
/// reserved for "live, currently happening" states (e.g. an
/// actively-downloading hero). No custom animation engine.
struct DSStatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: Color
    let pulsing: Bool
    let size: CGFloat

    init(tint: Color, pulsing: Bool = false, size: CGFloat = 8) {
        self.tint = tint
        self.pulsing = pulsing
        self.size = size
    }

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: size))
            .foregroundStyle(tint)
            .symbolEffect(.pulse, options: .repeating, isActive: pulsing && !reduceMotion)
            .accessibilityHidden(true)
    }
}
