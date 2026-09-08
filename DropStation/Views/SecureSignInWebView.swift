import SwiftUI
@preconcurrency import WebKit

/// DSM owns credentials and push/OTP challenges. The explicit completion action
/// also works when DSM finishes with XHR without navigating to a desktop URL.
struct SecureSignInWebView: View {
    let loginURL: URL
    let onSuccess: (AuthSession, [HTTPCookie]) -> Void
    let onCancel: () -> Void
    @StateObject private var browser = WebSignInBrowser()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(loginURL.host ?? "NAS", systemImage: "server.rack")
                        .font(.subheadline.weight(.medium))
                    Text("Complete sign-in in DSM, then check access to Download Station.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = browser.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if browser.loading || browser.checking { ProgressView() }
                    Button {
                        Task { await browser.checkAccess(loginURL: loginURL, onSuccess: onSuccess) }
                    } label: {
                        Label("Check Download Station access", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(browser.loading || browser.checking)
                }
                .padding()
                .background(.regularMaterial)
                WebViewContainer(browser: browser, loginURL: loginURL)
            }
            .navigationTitle("Web sign-in · Experimental")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", role: .cancel) { browser.cancel(); onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reload", systemImage: "arrow.clockwise") { browser.reload(loginURL) }
                        .disabled(browser.checking)
                }
            }
            .alert("Trust this NAS certificate?", isPresented: Binding(
                get: { browser.certificate != nil },
                set: { if !$0 { browser.certificate = nil } }
            ), presenting: browser.certificate) { certificate in
                Button("Trust and reload") {
                    CertPinStore.pin(certificate.fingerprint, for: certificate.host)
                    browser.certificate = nil
                    browser.reload(loginURL)
                }
                Button("Cancel", role: .cancel) { browser.certificate = nil }
            } message: { certificate in
                Text("Verify the SHA-256 fingerprint with your NAS administrator before trusting it. A changed certificate must be verified again.\n\n\(certificate.host)\n\(certificate.fingerprint)")
            }
        }
    }
}

@MainActor
private final class WebSignInBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var loading = true
    @Published var checking = false
    @Published var message: String?
    @Published var certificate: (host: String, fingerprint: String)?
    var webView: WKWebView?
    private var active = true
    private var revision = 0
    private let trustCoordinator = ServerTrustCoordinator()

    func cancel() {
        active = false
        revision += 1
        webView?.stopLoading()
        webView?.navigationDelegate = nil
    }

    func reload(_ url: URL) {
        message = nil
        webView?.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        revision += 1
        loading = true
        message = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        loading = false
        if (error as NSError).code == NSURLErrorCancelled { return }
        message = String(localized: "The NAS page could not load. Check the address, connection, and certificate, then reload.")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        revision += 1
        message = String(localized: "The NAS page stopped responding. Reload to try again.")
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        trustCoordinator.handle(challenge) { disposition, credential in
            if let fingerprint = self.trustCoordinator.takeRejectedFingerprint(for: challenge.protectionSpace.host) {
                self.certificate = (challenge.protectionSpace.host, fingerprint)
            }
            completionHandler(disposition, credential)
        }
    }

    func checkAccess(loginURL: URL, onSuccess: (AuthSession, [HTTPCookie]) -> Void) async {
        guard active, !checking, let webView, let pageURL = webView.url,
              WebSessionBridge.sameOrigin(pageURL, loginURL) else {
            message = String(localized: "Return to the configured NAS page before checking access.")
            return
        }
        checking = true
        message = nil
        let capturedRevision = revision
        defer { checking = false }
        do {
            // Documented SYNO.API.Auth.token call, inside the browser's cookie
            // context. No private challenge replay, credential scraping, or
            // token-bearing navigation URLs. Redirects fail closed.
            let result = try await webView.callAsyncJavaScript("""
                if (location.origin !== new URL(expectedURL).origin) throw new Error('Origin changed');
                const controller = new AbortController();
                const timer = setTimeout(() => controller.abort(), 10000);
                try {
                    const response = await fetch('/webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=token', {
                        credentials: 'same-origin', redirect: 'error', cache: 'no-store', signal: controller.signal
                    });
                    if (!response.ok) throw new Error('Token request failed');
                    return await response.text();
                } finally { clearTimeout(timer); }
                """, arguments: ["expectedURL": loginURL.absoluteString], in: nil, contentWorld: .page)
            guard active, capturedRevision == revision, let currentURL = webView.url,
                  WebSessionBridge.sameOrigin(currentURL, loginURL), let json = result as? String else { return }
            let response = try JSONDecoder().decode(APIResponse<SynoTokenData>.self, from: Data(json.utf8))
            guard response.success, let data = response.data else {
                message = String(localized: "DSM has not confirmed the web session. Finish sign-in and 2FA, then check again. If this NAS does not support the handoff, use a verification code.")
                return
            }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard active, capturedRevision == revision else { return }
            let apiURL = loginURL.appendingPathComponent("webapi/entry.cgi")
            guard let auth = WebSessionBridge.session(cookies: cookies, apiURL: apiURL, token: data.synotoken) else {
                message = String(localized: "No unambiguous NAS session was found. Finish sign-in or reload and try again.")
                return
            }
            let applicable = WebSessionBridge.applicableCookies(cookies, to: apiURL)
            active = false
            onSuccess(auth, applicable)
        } catch {
            guard active, capturedRevision == revision else { return }
            message = String(localized: "The web session could not be checked. Check the connection and try again, or cancel and use a verification code.")
        }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let browser: WebSignInBrowser
    let loginURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = browser
        browser.webView = webView
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        webView.load(URLRequest(url: loginURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: ()) {
        (webView.navigationDelegate as? WebSignInBrowser)?.cancel()
    }
}
