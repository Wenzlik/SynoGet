import SwiftUI

/// DropStation login screen: centered card with a single column of fields
/// (username, password, optional server config disclosure) and one big Sign in button.
/// After the first attempt the same card switches to a 2FA challenge layout when the
/// server demands a second factor.
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore

    /// Persisted across launches so a returning user lands on the same
    /// auth flow they last used (OTP vs. Secure SignIn web).
    @AppStorage(AuthMethodSettings.storageKey) private var authMethodRaw: String = AuthMethod.otp.rawValue
    private var authMethod: Binding<AuthMethod> {
        Binding(
            get: { AuthMethod(rawValue: authMethodRaw) ?? .otp },
            set: { authMethodRaw = $0.rawValue }
        )
    }

    @State private var scheme: ServerConfig.Scheme = .https
    @State private var host: String = ""
    @State private var port: String = "5001"
    @State private var account: String = ""
    @State private var password: String = ""
    @State private var otpCode: String = ""
    @State private var serverExpanded: Bool = false
    @State private var showingSettings: Bool = false
    /// Presents the WKWebView-backed DSM sign-in sheet. Carries the
    /// computed login URL so the sheet can build itself without
    /// re-doing the host/scheme/port arithmetic. Wrapped in
    /// `IdentifiableURL` because `.sheet(item:)` requires `Identifiable`.
    @State private var webSignInURL: IdentifiableURL?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backgroundGradient.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    header
                    card
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)

            settingsButton
        }
        .onAppear(perform: prefill)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(item: $webSignInURL) { wrapped in
            SecureSignInWebView(
                loginURL: wrapped.url,
                onSuccess: { sid, cookies in
                    let captured = ServerConfig(
                        scheme: scheme,
                        host: host,
                        port: Int(port) ?? 5001,
                        // The web flow doesn't expose which DSM user
                        // signed in — DSM identifies the session purely
                        // by SID at this point. Fall back to whatever
                        // the user typed in the (now-hidden) form, or
                        // an empty string if they used Secure SignIn
                        // straight off the bat. The session probe will
                        // populate state from the actual user later.
                        account: account
                    )
                    webSignInURL = nil
                    Task {
                        await session.completeWebSignIn(
                            config: captured,
                            sid: sid,
                            cookies: cookies
                        )
                    }
                },
                onCancel: {
                    webSignInURL = nil
                }
            )
        }
    }

    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(12)
                .glassEffect(.regular, in: .circle)
        }
        .padding(.top, 8)
        .padding(.trailing, 16)
        .accessibilityLabel("Settings")
    }

    // MARK: - Header

    private var backgroundGradient: some View { DSBackground() }

    private var header: some View {
        VStack(spacing: DSSpacing.md) {
            brandDisc
            Text("DropStation").font(.largeTitle.weight(.semibold))
            Text(welcomeSubtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var brandDisc: some View {
        Image("BrandIcon")
            .resizable()
            .frame(width: 88, height: 88)
            .clipShape(.rect(cornerRadius: DSRadius.card))
            .accessibilityHidden(true)
    }

    private var welcomeSubtitle: String {
        if !session.config.host.isEmpty {
            return String(localized: "Sign in to \(session.config.host)")
        }
        return String(localized: "Sign in to your Synology Download Station")
    }

    // MARK: - Card

    @ViewBuilder
    private var card: some View {
        DSCard(.primary) {
            VStack(spacing: DSSpacing.lg) {
                if case .twoFactorRequired = session.state {
                    twoFactorContent
                } else if case .validatingApiAccess = session.state {
                    validatingApiAccessContent
                } else if case .sessionUnauthorized(let reason) = session.state {
                    sessionUnauthorizedContent(reason: reason)
                } else {
                    credentialsContent
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: session.state)
    }

    // MARK: - Credentials sub-view

    @ViewBuilder
    private var credentialsContent: some View {
        // Picker only renders when the experimental Secure SignIn flag
        // is on (see AuthMethodSettings.experimentalEnabled). Default
        // user-facing build hides the picker and shows the OTP form
        // unconditionally — Secure SignIn via WKWebView too often hits
        // Synology error 105 to expose to regular users yet.
        if AuthMethodSettings.experimentalEnabled {
            authMethodPicker
            switch AuthMethodSettings.effective {
            case .otp:
                otpCredentialsContent
            case .secureSignInWeb:
                secureSignInCredentialsContent
            }
        } else {
            otpCredentialsContent
        }
    }

    /// Compact picker that lets the user flip between the two 2FA flows
    /// before they commit credentials. Rendered as a segmented control so
    /// it stays out of the way visually but the two options are both
    /// always visible (vs. hiding one behind a menu).
    private var authMethodPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Sign-in method", selection: authMethod) {
                ForEach(AuthMethod.allCases) { method in
                    Label(method.label, systemImage: method.systemImage).tag(method)
                }
            }
            .pickerStyle(.segmented)
            Text(authMethod.wrappedValue.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 4)
    }

    /// Username + password + server config, as before. The OTP six-digit
    /// code (when required) is collected by `twoFactorContent` on a
    /// second pass through the card.
    @ViewBuilder
    private var otpCredentialsContent: some View {
        IconField(systemImage: "person.crop.circle", placeholder: "Username", text: $account)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.username)

        IconSecureField(systemImage: "lock", placeholder: "Password", text: $password)
            .textContentType(.password)

        DisclosureGroup(isExpanded: $serverExpanded) {
            serverConfigFields
        } label: {
            HStack {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text("Server").font(.callout)
                Spacer()
                Text(serverSummary)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)

        if case .error(let message) = session.state {
            inlineErrorLabel(message)
        }

        signInButton(label: "Sign in", isWorking: session.state == .authenticating) {
            Task { await login() }
        }
        .disabled(!credentialsValid || session.state == .authenticating)
    }

    /// Secure SignIn web flow card. The actual sign-in (username,
    /// password, Approve sign-in push approval / OTP) runs inside the
    /// DSM web UI itself, hosted in a `WKWebView` we present as a
    /// sheet. We just collect host details here and hand off.
    @ViewBuilder
    private var secureSignInCredentialsContent: some View {
        DisclosureGroup(isExpanded: $serverExpanded) {
            serverConfigFields
        } label: {
            HStack {
                Image(systemName: "server.rack").foregroundStyle(.secondary)
                Text("Server").font(.callout)
                Spacer()
                Text(serverSummary)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)

        Text("Tap Continue to open your NAS sign-in page. Enter your username and password there, then approve the push notification in Synology Secure SignIn.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)

        if case .error(let message) = session.state {
            inlineErrorLabel(message)
        }

        signInButton(label: "Continue to web sign-in", isWorking: false) {
            presentWebSignIn()
        }
        .disabled(!hostValid)
    }

    private var hostValid: Bool {
        !host.isEmpty && Int(port) != nil
    }

    private func presentWebSignIn() {
        guard let portInt = Int(port),
              let url = ServerConfig(scheme: scheme, host: host, port: portInt, account: account).baseURL
        else { return }
        webSignInURL = IdentifiableURL(url: url)
    }

    private var serverConfigFields: some View {
        VStack(spacing: 12) {
            Picker("Scheme", selection: $scheme) {
                ForEach(ServerConfig.Scheme.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented)

            IconField(systemImage: "network", placeholder: "Host or IP", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)

            IconField(systemImage: "number", placeholder: "Port", text: $port)
                .keyboardType(.numberPad)
        }
        .padding(.top, 8)
    }

    private var serverSummary: String {
        host.isEmpty ? "Not configured" : "\(scheme.rawValue)://\(host):\(port)"
    }

    private var credentialsValid: Bool {
        !host.isEmpty && !account.isEmpty && !password.isEmpty && Int(port) != nil
    }

    // MARK: - 2FA sub-view

    @ViewBuilder
    private var twoFactorContent: some View {
        stateHeader(
            systemImage: "lock.shield",
            tint: .accentColor,
            eyebrow: "Verification",
            title: "Enter your 6-digit code",
            body: "Open your authenticator app — Synology Secure SignIn (Codes tab), Google Authenticator, 1Password, etc. — and enter the 6-digit code."
        )

        IconField(systemImage: "number.square", placeholder: "6-digit code", text: $otpCode)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)

        if case .error(let message) = session.state {
            inlineErrorLabel(message)
        }

        signInButton(
            label: "Verify code",
            isWorking: session.state == .authenticating
        ) {
            Task { await session.submitOTP(otpCode) }
        }
        .disabled(otpCode.count < 6 || session.state == .authenticating)

        Button("Cancel", role: .cancel) {
            session.cancelTwoFactor()
            otpCode = ""
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - Validating API access (post-web-sign-in probe) sub-view

    /// Brief progress card shown while we POST a real Download Station
    /// request to confirm the cookies harvested from WKWebView
    /// actually grant API access. Either flips to the task list
    /// (`.loggedIn`) or to the recovery card (`.sessionUnauthorized`)
    /// in well under a second; the spinner is mostly there so the
    /// user doesn't see the login form blink between sheet dismissal
    /// and final state.
    @ViewBuilder
    private var validatingApiAccessContent: some View {
        VStack(spacing: DSSpacing.md) {
            stateDisc(systemImage: "checkmark.shield", tint: .accentColor)
            DSEyebrow("Secure SignIn verified")
            Text("Checking Download Station access…")
                .font(.headline.weight(.medium))
                .multilineTextAlignment(.center)
            ProgressView()
                .padding(.top, DSSpacing.xs)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Session-unauthorized (105 recovery) sub-view

    /// Shown when the active session is no longer good for Download
    /// Station. Reached from two distinct paths:
    ///
    ///   - Foreground probe (or list refresh) returns 105/106/107/119
    ///     after we believed we were signed in. The reason string
    ///     starts with "Session expired".
    ///   - Post-web-sign-in probe returns 105 (web identity verified
    ///     but DSM didn't extend auth to Download Station).
    ///
    /// The heading and icon adapt to the case so the user gets honest
    /// copy in both, but the recovery actions are identical: switch to
    /// OTP (the only flow that reliably mints a DownloadStation-scoped
    /// SID), retry the web sign-in, or sign out entirely.
    @ViewBuilder
    private func sessionUnauthorizedContent(reason: String) -> some View {
        // Heuristic on the reason string keeps the state machine in
        // SessionStore simple while still letting the view show
        // case-appropriate copy. Both reasons originate in
        // SessionStore so the contract is local.
        let isExpiry = reason.localizedCaseInsensitiveContains("expired")
        let title = isExpiry ? "Session expired" : "Re-authentication required"
        let symbol = isExpiry ? "clock.badge.exclamationmark" : "exclamationmark.shield"
        let eyebrow: LocalizedStringKey = isExpiry ? "Session" : "Recovery"

        stateHeader(
            systemImage: symbol,
            tint: .orange,
            eyebrow: eyebrow,
            title: LocalizedStringKey(title),
            body: nil,
            customBody: AnyView(
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            )
        )

        // Primary recovery — switch to OTP. This is the only path
        // that reliably mints a session DSM accepts for Download
        // Station: auth.cgi with username + password + (optional)
        // otp_code returns a SID scoped to whatever `session=` we
        // ask for, including DownloadStation. The button signs the
        // user out (preserving the password in Keychain so silent
        // re-login can use it) and flips AuthMethod to .otp; they
        // land back on the credentials form.
        signInButton(label: "Re-authenticate with verification code", isWorking: false) {
            Task { await session.switchToOTPAndSignOut() }
        }

        // Secure SignIn retry is only exposed when the experimental
        // picker is on — otherwise we'd be offering the user a flow
        // they can't see anywhere else in the login UI.
        if AuthMethodSettings.experimentalEnabled {
            Button {
                Task { await session.retryWebSignIn() }
            } label: {
                Label("Try Secure SignIn", systemImage: "arrow.clockwise")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }

        Button(role: .destructive) {
            Task { await session.logout() }
        } label: {
            Text("Sign out")
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    // MARK: - State header helpers

    /// Shared visual shell for the card's state-specific sub-
    /// views (`twoFactorContent`, `validatingApiAccessContent`,
    /// `sessionUnauthorizedContent`). Phase-3 hierarchy: 56 pt
    /// tinted Liquid Glass disc on top, uppercase tracked
    /// DSEyebrow eyebrow, `.headline.weight(.medium)` title,
    /// optional body copy.
    ///
    /// `body` covers the common case (plain copy paragraph) and
    /// `customBody` the rare one (the sessionUnauthorized state
    /// renders the dynamic `reason` string with slightly
    /// different styling). Callers pass one or the other.
    @ViewBuilder
    private func stateHeader(
        systemImage: String,
        tint: Color,
        eyebrow: LocalizedStringKey,
        title: LocalizedStringKey,
        body: LocalizedStringKey?,
        customBody: AnyView? = nil
    ) -> some View {
        VStack(spacing: DSSpacing.sm) {
            stateDisc(systemImage: systemImage, tint: tint)
            DSEyebrow(eyebrow)
            Text(title)
                .font(.headline.weight(.medium))
                .multilineTextAlignment(.center)
            if let body {
                Text(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let customBody {
                customBody
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 56 pt tinted Liquid Glass disc — the icon treatment that
    /// the dashboard activity row uses for type icons, scaled up
    /// for screen-level state communication. Disc fill, glyph
    /// foreground, and stroke border all share the caller's
    /// status colour so the disc reads as a single visual tone
    /// rather than two competing accents.
    private func stateDisc(systemImage: String, tint: Color) -> some View {
        DSIconTile(symbol: systemImage, tint: tint)
    }

    // MARK: - Common buttons

    @ViewBuilder
    private func signInButton(label: LocalizedStringKey, isWorking: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text(label).font(.body.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DSSpacing.xs)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    private func inlineErrorLabel(_ message: String) -> some View {
        // DSStatusBadge is the Phase-3 channel for exceptional
        // state (Offline / Error / Reconnecting / Beta). An auth
        // failure is exactly that, so the badge fits — caption
        // capsule tinted red with the warning glyph leading.
        // Wrapped in an HStack so the badge stays leading-aligned
        // inside the card rather than centred.
        HStack {
            DSStatusBadge(
                LocalizedStringKey(message),
                tint: .red,
                systemImage: "exclamationmark.triangle.fill"
            )
            Spacer(minLength: 0)
        }
        .padding(.vertical, DSSpacing.xs)
    }

    // MARK: - Actions

    private func prefill() {
        let cfg = session.config
        scheme = cfg.scheme
        host = cfg.host
        port = String(cfg.port)
        account = cfg.account
        serverExpanded = host.isEmpty
        // Prefill the saved password when "Remember password" is on, so a
        // returning user who lands on the form (rather than auto-advancing
        // straight to the OTP screen) doesn't have to retype it.
        if PasswordPersistenceSettings.enabled, !cfg.account.isEmpty {
            password = KeychainStorage.password(for: cfg.account) ?? ""
        }
    }

    private func login() async {
        guard let portInt = Int(port) else { return }
        let cfg = ServerConfig(scheme: scheme, host: host, port: portInt, account: account)
        await session.login(config: cfg, password: password)
    }
}

/// `.sheet(item:)` requires the payload to be `Identifiable`. `URL`
/// isn't (and conforming it globally would risk colliding with other
/// code), so wrap it for the one place we need it.
private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Field components

/// Background treatment shared by both form fields — Phase-3
/// `.regularMaterial` + half-point separator hairline, the same
/// surface tier the rest of the app's secondary surfaces use.
/// Replaces the previous `.background(.background.tertiary, ...)`
/// look from Phase 1.
private extension View {
    func loginFieldSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.tile, style: .continuous)
        return self
            .padding(.horizontal, DSSpacing.md)
            .padding(.vertical, DSSpacing.md)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.dsSurfaceHairline, lineWidth: 0.5))
    }
}

private struct IconField: View {
    let systemImage: String
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            TextField(placeholder, text: $text)
        }
        .loginFieldSurface()
    }
}

private struct IconSecureField: View {
    let systemImage: String
    let placeholder: LocalizedStringKey
    @Binding var text: String
    @State private var revealed: Bool = false

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            if revealed {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                SecureField(placeholder, text: $text)
            }
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .loginFieldSurface()
    }
}
