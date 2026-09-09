import SwiftUI

/// Full-screen "we can't reach the NAS right now" surface, shown when
/// `SessionStore` is in `.connectionLost`. The saved SID is intact and
/// will be reused as soon as we can reach DSM again — there is no need
/// to ask the user for credentials, just to wait for the network to
/// come back (or for them to tap Retry).
///
/// NWPathMonitor in SessionStore handles automatic retry the moment a
/// network path goes `.satisfied`, so most users see this view for the
/// few seconds between a Wi-Fi/cellular handoff and the next probe.
/// The Retry button is the manual escape hatch for cases where the
/// monitor reports satisfied but the NAS itself is still unreachable
/// (e.g. the user opened a captive-portal-protected Wi-Fi).
struct ConnectionLostView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var isRetrying = false

    var body: some View {
        ZStack {
            DSBackground()

            VStack(spacing: DSSpacing.lg) {
                Spacer(minLength: 0)

                DSIconTile(symbol: "wifi.exclamationmark", tint: .orange)

                VStack(spacing: DSSpacing.sm) {
                    Text("Connection lost")
                        .font(.title2.weight(.semibold))
                    Text("Your session is saved. We’ll reconnect automatically when the NAS is reachable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DSSpacing.lg)
                }

                Button {
                    guard !isRetrying else { return }
                    isRetrying = true
                    Task {
                        await session.retryConnection()
                        isRetrying = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isRetrying {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isRetrying ? "Retrying…" : "Retry now")
                            .font(.body.weight(.semibold))
                    }
                    .frame(minWidth: 180)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 20)

                }
                .buttonStyle(.glassProminent)
                .disabled(isRetrying)
                .padding(.top, DSSpacing.sm)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpacing.lg)
        }
    }
}
