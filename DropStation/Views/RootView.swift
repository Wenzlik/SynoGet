import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var taskStore: DownloadTaskStore

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                DSLoadingView("Restoring session…")
            case .loggedIn:
                LoggedInShell(session: session)
            case .connectionLost:
                ConnectionLostView()
            case .untrustedCertificate(let host, let fingerprint, let isCertChange):
                CertificateTrustView(host: host, fingerprint: fingerprint, isCertChange: isCertChange)
            case .loggedOut, .authenticating, .twoFactorRequired, .validatingApiAccess, .sessionUnauthorized, .error:
                LoginView()
            }
        }
        .onChange(of: session.state) { _, newState in
            // Single source of truth for the shared task store's
            // polling lifecycle. Starting / stopping at the
            // SessionStore.state boundary keeps the views simple
            // (they no longer call `.startAutoRefresh` from
            // `.task`) and avoids cross-tab races when both views
            // are alive inside the TabView.
            switch newState {
            case .loggedIn:
                taskStore.startAutoRefresh()
                Task { await taskStore.refresh() }
            case .loggedOut, .authenticating, .twoFactorRequired,
                 .validatingApiAccess, .sessionUnauthorized, .error,
                 .restoring, .untrustedCertificate:
                taskStore.stopAutoRefresh()
            case .connectionLost:
                // ConnectionLostView handles its own retry. The
                // store retains its last good tasks so the user
                // doesn't see the list emptied while reconnecting.
                taskStore.stopAutoRefresh()
            }
        }
    }
}

/// Two-tab post-login shell: Dashboard (default) + Downloads.
/// Each tab owns its own `NavigationStack` so sheets and pushed
/// destinations stay scoped to one tab. The TabView selection
/// binds into `NavigationStore.selectedTab` so any post-login
/// surface can route the user across tabs — used by the
/// dashboard's "See all →" link into the Downloads tab.
private struct LoggedInShell: View {
    let session: SessionStore
    @EnvironmentObject private var navigation: NavigationStore
    @EnvironmentObject private var taskStore: DownloadTaskStore

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            DashboardView(session: session, store: taskStore)
                .tabItem {
                    Label("Dashboard", systemImage: "rectangle.grid.2x2")
                }
                .tag(NavigationStore.Tab.dashboard)
            TaskListView(session: session, store: taskStore)
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .tag(NavigationStore.Tab.downloads)
        }
        .tabBarMinimizeBehavior(.never)
    }
}
