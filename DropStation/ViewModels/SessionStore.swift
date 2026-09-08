import Foundation
import Network
import SwiftUI
@preconcurrency import WebKit

@MainActor
final class SessionStore: ObservableObject {
    enum State: Equatable {
        case restoring
        case loggedOut
        case authenticating
        /// First-stage credentials accepted; server is waiting for a 6-digit
        /// verification code from an authenticator app (Synology Secure SignIn
        /// Codes tab, Google Authenticator, 1Password, etc.).
        case twoFactorRequired
        /// Brief intermediate state after a Secure SignIn web sign-in:
        /// the WKWebView's auth round-trip succeeded, but we haven't yet
        /// confirmed Download Station accepts the resulting session.
        /// Shown as "Checking Download Station access…" with a spinner.
        /// Either flips to `.loggedIn` or
        /// `.sessionUnauthorized` depending on the probe outcome.
        case validatingApiAccess
        /// Terminal "fully authenticated" state — Download Station API
        /// probe came back success=true. Only this state grants access
        /// to the main task list.
        case loggedIn
        /// Download Station rejected the session, or a web candidate could
        /// not be checked. Recovery offers retry when a candidate remains,
        /// a fresh web login, and the verification-code fallback.
        case sessionUnauthorized(reason: String)
        /// The saved SID is still considered valid (we did not get a
        /// DSM-confirmed expiry code), but the NAS is unreachable —
        /// offline, DNS, TLS handshake, Wi-Fi/cellular handoff,
        /// connection lost mid-request, 5xx, etc. UX surface is a
        /// "Connection lost / Your session is saved / We'll reconnect
        /// when the NAS is reachable" card with a Retry affordance.
        /// Auto-retries when `NWPathMonitor` reports network back.
        case connectionLost
        /// The NAS presented a self-signed certificate the user
        /// hasn't trusted (or a previously-pinned cert that changed).
        /// UX surface is a "trust this server?" prompt showing the
        /// SHA-256 fingerprint; on confirm we pin it and retry. The
        /// saved SID (if any) is preserved — this isn't an auth
        /// failure, it's a trust decision. `isCertChange` is true
        /// when a pin already existed for the host but didn't match
        /// (cert rotated, or possible MITM) — the prompt warns more
        /// strongly in that case.
        case untrustedCertificate(host: String, fingerprint: String, isCertChange: Bool)
        case error(String)
    }

    /// Convenience predicate — `if case .connectionLost = self`-style
    /// pattern matching gets tedious in didSet observers.
    private static func isConnectionLost(_ state: State) -> Bool {
        if case .connectionLost = state { return true }
        return false
    }

    @Published private(set) var state: State = .restoring {
        didSet {
            let wasOffline = Self.isConnectionLost(oldValue)
            let isOffline = Self.isConnectionLost(state)
            if isOffline && !wasOffline { startNetworkMonitor() }
            if wasOffline && !isOffline { stopNetworkMonitor() }
        }
    }
    @Published private(set) var config: ServerConfig = ServerConfigStore.load() ?? .default
    @Published var pendingMagnetLink: String?
    /// A `.torrent` file the user opened into the app from Files /
    /// Safari / Mail ("Open in DropStation"). Consumed by AddTaskView,
    /// which preloads it into the file picker and switches to File mode.
    @Published var pendingTorrentFile: PendingTorrentFile?

    /// Active NWPathMonitor while we're in `.connectionLost`. Comes up
    /// when we transition into the state and tears down when we leave
    /// it, so we're not burning radio polling outside of an offline
    /// window. The handler kicks a retry probe as soon as the path
    /// reports `.satisfied`.
    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.wenzlik.DropStation.network-monitor")

    let client: SynologyAPIClient

    init(client: SynologyAPIClient = SynologyAPIClient()) {
        self.client = client
    }

    @Published private(set) var isVerifyingOTP = false
    @Published private(set) var otpError: String?
    @Published private(set) var isWebRecovery = false
    private var pendingWebSession: (auth: AuthSession, cookies: [HTTPCookie])?
    var canRetryWebValidation: Bool { pendingWebSession != nil }

    /// Credentials captured during the first login attempt, kept in memory only for the
    /// duration of a 2FA challenge so submitOTP can re-issue the request without
    /// prompting the user for them again.
    private var pendingCredentials: PendingCredentials?

    private struct PendingCredentials {
        let config: ServerConfig
        let password: String
    }

    /// Guard against running the launch-time session-restore twice. SwiftUI's
    /// `.task` modifier can fire again if the host view is re-attached (e.g.
    /// scenePhase transitions on some iOS builds), and we don't want to clobber
    /// the user's logged-in or login-form state with a second `.restoring`
    /// pass.
    private var didRestoreOnLaunch = false

    // MARK: - Restore

    /// Entry point for app-launch session restore. Wired from `DropStationApp`'s
    /// `WindowGroup` via `.task { await session.restoreOnLaunch() }` instead of
    /// being fired from `init()` — that earlier pattern forced a detached
    /// `Task { ... }` because SwiftUI requires `@StateObject` inits to be
    /// synchronous, which is less structured and harder to cancel/observe.
    /// Idempotent on repeat calls.
    func restoreOnLaunch() async {
        guard !didRestoreOnLaunch else { return }
        didRestoreOnLaunch = true
        await restoreSession()
    }

    /// Try to restore a session on app launch. Delegates to the shared
    /// `probeStoredSession` so a manual Retry tap from the offline
    /// card takes exactly the same code path.
    private func restoreSession() async {
        // If the user has password persistence turned off, make sure no
        // stored password lingers (covers turning the toggle off on a
        // prior run, plus any legacy credential an older build left
        // behind). When it's on we keep the password so an expired
        // session can re-auth with only an OTP prompt.
        if !PasswordPersistenceSettings.enabled {
            purgeStoredPasswordIfPresent()
        }
        await probeStoredSession()
    }

    /// User-driven retry from the `.connectionLost` card. Re-probes
    /// the saved SID against Download Station; success → `.loggedIn`,
    /// auth-expired → `.loggedOut`, still-offline → stay in
    /// `.connectionLost`. No-op if we're somehow not in the offline
    /// state any more (e.g. NWPathMonitor's auto-retry beat the user
    /// to it).
    func retryConnection() async {
        guard case .connectionLost = state else { return }
        DSLog.session("retryConnection: user-initiated retry")
        state = .restoring
        await probeStoredSession()
    }

    /// Core "is the saved session still alive?" probe. Wired from:
    ///
    ///   - launch via `restoreSession` (first run after process start)
    ///   - manual retry via `retryConnection` (user tapped Retry on
    ///     the offline card)
    ///   - automatic retry via `NWPathMonitor.pathUpdateHandler`
    ///     (network came back while we were in `.connectionLost`)
    ///
    /// Branching on the result is the only place where we decide
    /// whether to drop the saved SID. Per the auth contract: **only
    /// DSM-confirmed session-expiry codes (105/106/107/119) delete the
    /// SID**. Transport-layer failures (timeout, DNS, network lost,
    /// TLS, 5xx) leave the SID in place and put us into
    /// `.connectionLost` so the user sees "session is saved, we'll
    /// reconnect" instead of a fresh login form.
    private func probeStoredSession() async {
        guard !config.host.isEmpty,
              let url = config.baseURL else {
            state = .loggedOut
            return
        }
        await client.configure(baseURL: url)

        guard let savedSession = KeychainStorage.authSession(for: accountAtHost) else {
            state = .loggedOut
            return
        }
        // If we also have Secure SignIn web cookies on file, rehydrate
        // them into HTTPCookieStorage.shared *before* probing the API.
        // Some DSM endpoints (the DS2 entry.cgi flow) honour the cookie
        // in addition to the `_sid` URL parameter.
        restoreCookiesFromKeychain()
        await client.restoreSession(savedSession)
        do {
            _ = try await client.listTasks()
            touchSessionMetadata()
            state = .loggedIn
        } catch let error as APIError where error.isSessionExpired {
            // DSM actively rejected the SID (105/106/107/119). This is
            // the *only* failure mode that wipes the persisted
            // session. Land on a fresh login form.
            DSLog.session("probeStoredSession: SID rejected (\(error.localizedDescription)); dropping")
            await clearStoredSession()
            // If we still hold the password, re-authenticate silently so
            // the user only has to enter an OTP rather than retype
            // everything on a fresh form.
            if await reauthWithStoredPassword() { return }
            state = .loggedOut
        } catch let error as APIError where error.serverTrustInfo != nil {
            // Self-signed certificate the user hasn't trusted yet.
            // Preserve the SID (it hasn't been confirmed dead) and
            // route to the trust prompt rather than the offline card —
            // retrying won't help until the user decides.
            routeToCertificateTrust(error)
        } catch let error as APIError where error.isTransient {
            // Offline / Wi-Fi handoff / server 5xx / TLS / DNS. Keep
            // the SID — it's almost certainly still valid; we just
            // can't talk to the NAS right now. Surface the offline
            // card and let NWPathMonitor / the user trigger a retry.
            DSLog.session("probeStoredSession: transient (\(error.localizedDescription)); preserving SID, going offline")
            state = .connectionLost
        } catch {
            // Decoding glitch, unexpected HTTP code, generic transport
            // error not caught above. We treat these like transient:
            // they shouldn't kick the user back to a login form,
            // because the SID hasn't been confirmed dead.
            DSLog.session("probeStoredSession: unexpected (\(error.localizedDescription)); preserving SID, going offline")
            state = .connectionLost
        }
    }

    /// Best-effort delete of any stored password. Called on launch when
    /// password persistence is OFF, so turning the toggle off on a prior
    /// run (or upgrading from a build that stored a password under a
    /// different policy) doesn't leave a credential behind. Idempotent
    /// and cheap when there's nothing to remove.
    private func purgeStoredPasswordIfPresent() {
        guard !config.account.isEmpty else { return }
        if KeychainStorage.password(for: config.account) != nil {
            DSLog.session("password persistence off — purging stored password")
            KeychainStorage.deletePassword(for: config.account)
        }
    }

    /// The saved password for the current account, when password
    /// persistence is on and one is stored. `nil` otherwise. Used to
    /// re-authenticate silently after a confirmed session expiry so the
    /// user only has to supply the rotating OTP code.
    private var storedPassword: String? {
        guard PasswordPersistenceSettings.enabled, !config.account.isEmpty else { return nil }
        return KeychainStorage.password(for: config.account)
    }

    /// After a confirmed session expiry, attempt to re-authenticate with
    /// the saved password. `login` lands on `.twoFactorRequired` (so the
    /// user types only the OTP) or straight on `.loggedIn` when 2FA isn't
    /// enabled. Returns `false` when no password is stored so callers can
    /// fall back to their normal expired-session UI.
    @discardableResult
    private func reauthWithStoredPassword() async -> Bool {
        guard let password = storedPassword else { return false }
        DSLog.session("reauthWithStoredPassword: silent re-login, expecting OTP challenge")
        await login(config: config, password: password)
        return true
    }

    /// Drop every persisted credential we hold for the current
    /// account+host, plus the in-memory SID on the API client. Used by
    /// every path that needs to invalidate a session: a rejected SID
    /// probe, an unauthorized list refresh, a logout. Idempotent.
    private func clearStoredSession() async {
        pendingWebSession = nil
        clearStoredKeychainSession()
        await client.clearSession()
        await client.clearAuthCookies()
    }

    /// Keychain-only teardown for callers that can't await (sync
    /// MainActor hooks). The caller is responsible for tearing the
    /// in-memory SID / cookies down separately via a `Task`.
    private func clearStoredKeychainSession() {
        KeychainStorage.deleteSID(for: accountAtHost)
        KeychainStorage.deleteCookies(for: accountAtHost)
        KeychainStorage.deleteSessionMetadata(for: accountAtHost)
    }

    // MARK: - Login

    /// Initial login from the form. If the server demands a second factor,
    /// transition to `.twoFactorRequired` and wait for the user to type a code.
    func login(config: ServerConfig, password: String) async {
        isWebRecovery = false
        otpError = nil
        self.config = config
        guard let url = config.baseURL else {
            state = .error(String(localized: "Invalid server URL."))
            return
        }
        await client.configure(baseURL: url)
        // Wipe any DSM trusted-device cookies left over from previous
        // logins. Without this, DSM may silently honour a stale `did`
        // cookie and skip the 2FA challenge entirely. Every form-driven
        // sign-in should be a fresh, fully-challenged login.
        await client.clearAuthCookies()
        state = .authenticating
        pendingCredentials = PendingCredentials(config: config, password: password)
        await attemptLogin(
            password: password,
            otpCode: nil,
            onOTPNeeded: { [weak self] in
                self?.state = .twoFactorRequired
            }
        )
    }

    /// Submit an OTP code from the 2FA challenge view.
    func submitOTP(_ otpCode: String) async {
        guard !isVerifyingOTP, otpCode.count == 6, otpCode.allSatisfy({ "0123456789".contains($0) }) else { return }
        guard let pending = pendingCredentials else {
            state = .error(String(localized: "Session lost. Please sign in again."))
            return
        }
        isVerifyingOTP = true
        otpError = nil
        defer { isVerifyingOTP = false }
        await attemptLogin(
            password: pending.password,
            otpCode: otpCode,
            onOTPNeeded: { [weak self] in
                self?.state = .twoFactorRequired
            }
        )
    }

    /// Bail out of the 2FA challenge — go back to the credentials form.
    func cancelTwoFactor() {
        guard !isVerifyingOTP else { return }
        otpError = nil
        pendingCredentials = nil
        state = .loggedOut
    }

    private func attemptLogin(
        password: String,
        otpCode: String?,
        onOTPNeeded: @escaping () -> Void
    ) async {
        do {
            try await performLogin(password: password, otpCode: otpCode)
            // Server config (host/port/account/scheme) is not a
            // credential — always remember it so the login form
            // prefills. The password is persisted separately, gated by
            // the "Remember password" preference, so an expired session
            // can re-auth with only an OTP prompt.
            ServerConfigStore.save(config)
            persistPasswordIfAllowed(password)
            pendingCredentials = nil
        } catch let error as APIError where error.isOTPRequired {
            onOTPNeeded()
        } catch let error as APIError where error.isOTPInvalid {
            otpError = String(localized: "Incorrect verification code. Try a new code.")
            state = .twoFactorRequired
        } catch let error as APIError where error.serverTrustInfo != nil {
            // First login to a self-signed NAS. Keep pendingCredentials
            // intact — trustCertificate() re-runs the login once the
            // user pins the cert.
            routeToCertificateTrust(error)
        } catch {
            if otpCode != nil {
                otpError = error.localizedDescription
                state = .twoFactorRequired
            } else {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// The single Synology `login` call. Sends just account/password/otpCode —
    /// no device-token plumbing. When "Remember session" is on, persists the
    /// returned SID plus a `SessionMetadata` sidecar; otherwise the SID stays
    /// in memory for the duration of the app run only.
    private func performLogin(password: String, otpCode: String?) async throws {
        let result = try await client.login(
            account: config.account,
            password: password,
            otpCode: otpCode
        )
        persistSessionIfAllowed(auth: result, cookies: [])
        state = .loggedIn
    }

    /// Persist the freshly-acquired SID + session metadata (and any
    /// Secure SignIn web cookies) when the user has opted in to
    /// "Remember session". A best-effort write — keychain failures
    /// don't break the active session, they just mean the next launch
    /// will require a fresh sign-in.
    /// Persist the account password to the Keychain when the user has
    /// opted in to "Remember password". Best-effort — a keychain write
    /// failure just means the next session expiry falls back to the full
    /// credentials form instead of an OTP-only prompt.
    private func persistPasswordIfAllowed(_ password: String) {
        guard PasswordPersistenceSettings.enabled, !config.account.isEmpty else { return }
        try? KeychainStorage.setPassword(password, for: config.account)
    }

    private func persistSessionIfAllowed(auth: AuthSession, cookies: [HTTPCookie]) {
        guard RememberSessionSettings.enabled else { return }
        try? KeychainStorage.setAuthSession(auth, for: accountAtHost)
        let stored = cookies.map(StoredCookie.init(cookie:))
        try? KeychainStorage.setCookies(stored, for: accountAtHost)
        try? KeychainStorage.setSessionMetadata(makeMetadata(), for: accountAtHost)
    }

    /// Build a fresh `SessionMetadata` snapshot for the current config.
    /// `createdAt` and `lastValidatedAt` are both set to `now` — the
    /// probe path bumps `lastValidatedAt` independently on every
    /// successful API round-trip.
    private func makeMetadata(now: Date = Date()) -> SessionMetadata {
        SessionMetadata(
            baseURL: config.baseURL?.absoluteString ?? "",
            account: config.account,
            sessionName: config.account.isEmpty ? "DSM web" : SessionMetadata.downloadStationSession,
            createdAt: now,
            lastValidatedAt: now
        )
    }

    /// Bump `lastValidatedAt` after a successful API call so the
    /// foreground probe knows the session is fresh. Reads the existing
    /// metadata to preserve `createdAt`; if nothing's on file (remember
    /// turned on mid-session, or first-ever launch after upgrade), we
    /// synthesize a record so the next probe still has something to
    /// throttle against.
    private func touchSessionMetadata() {
        guard RememberSessionSettings.enabled else { return }
        var meta = KeychainStorage.sessionMetadata(for: accountAtHost) ?? makeMetadata()
        meta.lastValidatedAt = Date()
        try? KeychainStorage.setSessionMetadata(meta, for: accountAtHost)
    }

    // MARK: - Logout

    /// Logout — invalidates the active session on every layer we know
    /// about. Touches:
    ///   - DSM server-side SID (best-effort, ignore failures)
    ///   - Keychain SID + Secure SignIn cookies + session metadata
    ///   - Any legacy password an older build may have left behind
    ///     (current builds never persist passwords)
    ///   - HTTPCookieStorage.shared (URLSession layer)
    ///   - WKWebsiteDataStore (anything the web-sign-in WKWebView left
    ///     behind in its non-persistent jar will already be gone, but
    ///     the default store may still have something from a prior
    ///     in-app browser run — wipe it for good measure)
    func logout() async {
        pendingCredentials = nil
        otpError = nil
        isWebRecovery = false
        try? await client.logout()
        await clearStoredSession()
        KeychainStorage.deletePassword(for: config.account)
        await clearWebsiteData()
        state = .loggedOut
    }

    /// Same as logout. Kept as a separate entry point because the
    /// Settings UI still surfaces it under a distinct "Forget this
    /// device" affordance with destructive-button styling — the user
    /// expectation differs (full wipe vs. casual sign-out) even though
    /// the underlying cleanup is now identical to `logout`.
    func forgetDevice() async {
        await logout()
    }

    /// Wipe cookies + local storage owned by `WKWebsiteDataStore.default()`.
    /// The Secure SignIn web sheet uses `.nonPersistent()` so its own
    /// jar dies with the sheet, but DSM may have set cookies in the
    /// default store at any earlier point (e.g. if a future revision
    /// opens DSM pages outside the sign-in sheet). Catching everything
    /// here keeps logout semantically honest.
    private func clearWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    /// A cookie SID is only a candidate. Preserve its CSRF context and require
    /// a real Download Station request before committing the session.
    /// 105 means permission denied, not proof of a session-name mismatch.
    func completeWebSignIn(config: ServerConfig, auth: AuthSession, cookies: [HTTPCookie]) async {
        await clearStoredSession()
        KeychainStorage.deletePassword(for: self.config.account)
        self.config = config
        // Web login does not prove the username entered in the native form.
        // An anonymous web-session slot also prevents password auto-login as
        // a different user after expiry. Settings displays the NAS instead.
        self.config.account = ""
        pendingCredentials = nil
        isWebRecovery = true
        guard let url = config.baseURL else {
            state = .error(String(localized: "Invalid server URL."))
            return
        }
        await client.configure(baseURL: url)
        pendingWebSession = (auth, cookies)
        await retryWebValidation()
    }

    func retryWebValidation() async {
        guard let candidate = pendingWebSession, state != .validatingApiAccess else { return }
        state = .validatingApiAccess
        await client.clearAuthCookies()
        for cookie in candidate.cookies { HTTPCookieStorage.shared.setCookie(cookie) }
        await client.restoreSession(candidate.auth)
        do {
            try await validateDownloadStationAccess()
            ServerConfigStore.save(config)
            persistSessionIfAllowed(auth: candidate.auth, cookies: candidate.cookies)
            pendingWebSession = nil
            isWebRecovery = false
            state = .loggedIn
        } catch let error as APIError where error.isSessionExpired {
            await clearStoredSession()
            state = .sessionUnauthorized(reason: String(localized: "DSM rejected Download Station access. Check this account’s application permissions in DSM, or sign in with a verification code. Web sign-in compatibility varies by NAS."))
        } catch let error as APIError where error.serverTrustInfo != nil {
            routeToCertificateTrust(error)
        } catch {
            // Keep the candidate only in memory. Retry does not repeat push/2FA,
            // and never saves an unvalidated session to the Keychain.
            state = .sessionUnauthorized(reason: String(localized: "Download Station access could not be checked. Your web session is kept for this attempt. Check the connection and retry."))
        }
    }

    /// Run a real Download Station request and require success=true.
    /// Throws on any failure (105, transient, decoding, etc.) so the
    /// caller can branch on `isUnauthorized` / `isTransient` and react
    /// appropriately. Used by `completeWebSignIn` as the gating probe
    /// between web sign-in and `.loggedIn`.
    private func validateDownloadStationAccess() async throws {
        _ = try await client.listTasks()
    }

    /// Recovery action from the `.sessionUnauthorized` card — re-open
    /// the Secure SignIn web flow without changing the user's saved
    /// auth-method preference. Implemented as "drop the half-broken
    /// session and go back to the login form"; the picker already
    /// shows `.secureSignInWeb`, so the next tap on Continue re-opens
    /// the WKWebView sheet.
    func retryWebSignIn() async {
        DSLog.session("retryWebSignIn — clearing session, returning to login form")
        await logout()
    }

    /// Called by `TaskListViewModel` when an API call comes back with
    /// "session does not have permission" or related auth-loss codes
    /// after we believed we were logged in. Drops the persisted SID +
    /// metadata + cookies (so the next launch doesn't immediately try
    /// the same dead session) and surfaces the recovery card with three
    /// options: re-authenticate, switch to OTP, or full sign out. The
    /// in-memory client state is torn down on a detached task because
    /// the caller is a synchronous hook.
    func handleUnauthorized(reason: String) {
        DSLog.session("handleUnauthorized: \(reason)")
        clearStoredKeychainSession()
        // Show the neutral restoring state while we try a silent re-auth;
        // if there's no stored password the Task falls straight through to
        // the recovery card, same as before.
        let canReauth = storedPassword != nil
        if canReauth { state = .restoring }
        Task {
            await client.clearSession()
            await client.clearAuthCookies()
            if await reauthWithStoredPassword() { return }
            state = .sessionUnauthorized(reason: reason)
        }
    }

    // MARK: - Self-signed certificate trust

    /// Route an `APIError.serverTrust` to the trust prompt. Reads
    /// `(host, fingerprint)` off the error, and flags `isCertChange`
    /// when a pin already exists for the host (it didn't match the
    /// presented cert — rotated cert or possible MITM). The SID and
    /// any in-flight `pendingCredentials` are deliberately left
    /// intact so `trustCertificate()` can resume whatever was
    /// happening.
    private func routeToCertificateTrust(_ error: APIError) {
        guard let info = error.serverTrustInfo else { return }
        let isCertChange = CertPinStore.pinnedFingerprint(for: info.host) != nil
        DSLog.session("routeToCertificateTrust: host=\(info.host) changed=\(isCertChange) fp=\(info.fingerprint)")
        state = .untrustedCertificate(
            host: info.host,
            fingerprint: info.fingerprint,
            isCertChange: isCertChange
        )
    }

    /// User confirmed the self-signed certificate. Pin the
    /// fingerprint, then resume: re-run the in-flight login when we
    /// were mid-sign-in (`pendingCredentials` set), otherwise
    /// re-probe the stored SID. The trust coordinator will now
    /// accept this exact certificate for the host.
    func trustCertificate(host: String, fingerprint: String) async {
        CertPinStore.pin(fingerprint, for: host)
        DSLog.session("trustCertificate: pinned \(fingerprint) for \(host)")
        state = .restoring
        if pendingWebSession != nil {
            await retryWebValidation()
        } else if let pending = pendingCredentials {
            await attemptLogin(
                password: pending.password,
                otpCode: nil,
                onOTPNeeded: { [weak self] in self?.state = .twoFactorRequired }
            )
        } else {
            await probeStoredSession()
        }
    }

    /// User declined to trust the certificate. Drop any in-flight
    /// login credentials and land on the login form so they can
    /// adjust the server config (e.g. switch scheme to http, fix
    /// the host) or simply back out.
    func declineCertificate() {
        DSLog.session("declineCertificate: returning to login form")
        pendingCredentials = nil
        pendingWebSession = nil
        state = .loggedOut
    }

    // MARK: - Network monitor (auto-reconnect from .connectionLost)

    /// Spin up an NWPathMonitor that watches for the network coming
    /// back. Called from the state `didSet` observer when we transition
    /// into `.connectionLost`. Cheap to leave running for the duration
    /// of the offline state; we tear it down again when we leave the
    /// state.
    ///
    /// The handler executes on a background queue (Network framework's
    /// requirement); we bounce back to the main actor before touching
    /// any session state.
    private func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        DSLog.session("startNetworkMonitor: watching for connectivity")
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard case .connectionLost = self.state else { return }
                DSLog.session("network back — auto-retrying probe")
                self.state = .restoring
                await self.probeStoredSession()
            }
        }
        monitor.start(queue: monitorQueue)
        pathMonitor = monitor
    }

    private func stopNetworkMonitor() {
        guard pathMonitor != nil else { return }
        DSLog.session("stopNetworkMonitor")
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    // MARK: - Foreground probe

    /// Throttled silent revalidation. Designed to run from
    /// `scenePhase == .active` on every foreground transition: if the
    /// SID hasn't been confirmed alive in the last `throttle` seconds,
    /// fire a cheap `listTasks` request and react to whatever DSM
    /// returns.
    ///
    /// Bails early — and silently — in the common case (nothing to
    /// probe, just-validated session, transient network blip), so the
    /// only user-visible effect is the recovery card popping when the
    /// session is genuinely gone.
    func probeIfStale(throttle: TimeInterval = 600) async {
        guard state == .loggedIn else { return }
        guard let meta = KeychainStorage.sessionMetadata(for: accountAtHost) else { return }
        let elapsed = Date().timeIntervalSince(meta.lastValidatedAt)
        guard elapsed >= throttle else { return }

        DSLog.session("probeIfStale: elapsed=\(Int(elapsed))s, probing")
        do {
            _ = try await client.listTasks()
            touchSessionMetadata()
        } catch let error as APIError where error.isSessionExpired {
            DSLog.session("probeIfStale: session expired — \(error.localizedDescription)")
            await clearStoredSession()
            if await reauthWithStoredPassword() { return }
            state = .sessionUnauthorized(reason: String(localized: "Session expired. Please re-authenticate with verification code."))
        } catch let error as APIError where error.serverTrustInfo != nil {
            // Cert became untrusted between launches (DSM cert rotated,
            // or a previously-pinned cert changed). Route to the trust
            // prompt; SID preserved.
            routeToCertificateTrust(error)
        } catch let error as APIError where error.isTransient {
            // Offline / handoff / 5xx. Saved SID is preserved; surface
            // the offline card so the user knows we're reconnecting
            // (rather than silently sitting on a stale task list).
            // NWPathMonitor will auto-retry the probe when the network
            // comes back.
            DSLog.session("probeIfStale: transient (\(error.localizedDescription)); preserving SID, going offline")
            state = .connectionLost
        } catch {
            // Decoding or unexpected HTTP — also leave the session
            // alone. We'd rather mis-classify than kick the user out
            // for a parser glitch. Stay in `.loggedIn`; if the next
            // ad-hoc API call fails the same way, the user gets a
            // refresh error banner but their session is untouched.
            DSLog.session("probeIfStale: ignored (\(error.localizedDescription))")
        }
    }

    // MARK: - Remember-session preference

    /// Settings-toggle entry point. Writes the user pref. Turning the
    /// toggle off clears the persisted SID + metadata + cookies — the
    /// "session" being remembered. The active in-memory session is
    /// left intact so the user can keep using the app for this run
    /// without an immediate re-sign-in.
    ///
    /// Password persistence is governed separately by
    /// `setRememberPassword`, so turning "Remember session" off only
    /// clears the SID/cookies/metadata — the saved password (if any) is
    /// left to its own toggle.
    func setRememberSession(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: RememberSessionSettings.storageKey)
        DSLog.session("rememberSession = \(enabled)")
        if !enabled {
            clearStoredKeychainSession()
        }
    }

    /// Settings-toggle entry point for password persistence. Turning it
    /// off deletes any saved password immediately; the active session is
    /// untouched. When on, the next successful sign-in stores the
    /// password so a later session expiry only needs the OTP code.
    func setRememberPassword(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PasswordPersistenceSettings.storageKey)
        DSLog.session("rememberPassword = \(enabled)")
        if !enabled {
            KeychainStorage.deletePassword(for: config.account)
        }
    }

    /// Recovery action — switch the auth method preference back to OTP
    /// and drop the session so the user lands on the standard login
    /// form. Useful when the Secure SignIn web flow consistently fails
    /// the DownloadStation upgrade for this NAS.
    func switchToOTPAndSignOut() async {
        UserDefaults.standard.set(AuthMethod.otp.rawValue, forKey: AuthMethodSettings.storageKey)
        await logout()
    }

    /// Hydrate `HTTPCookieStorage.shared` from any cookies we previously
    /// persisted for this account+host. Filters out anything past its
    /// expiry — DSM session cookies routinely have multi-week
    /// lifetimes, but the user might also be coming back to a launch
    /// that already lapsed. No-op when nothing is stored.
    private func restoreCookiesFromKeychain() {
        guard let stored = KeychainStorage.cookies(for: accountAtHost),
              !stored.isEmpty else { return }
        guard let apiURL = config.baseURL?.appendingPathComponent("webapi/entry.cgi") else { return }
        let cookies = stored.compactMap { $0.makeHTTPCookie() }
        for cookie in WebSessionBridge.applicableCookies(cookies, to: apiURL) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// Handle content opened from outside the app: a `magnet:` link
    /// (from Safari) or a `.torrent` file ("Open in DropStation" from
    /// Files / Mail / Safari downloads). The file is read here, while
    /// the security-scoped URL is still valid, and stashed as
    /// `pendingTorrentFile` for AddTaskView to pick up.
    func handleIncomingURL(_ url: URL) {
        if url.scheme?.lowercased() == "magnet" {
            pendingMagnetLink = url.absoluteString
            return
        }
        if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                pendingTorrentFile = PendingTorrentFile(
                    name: url.lastPathComponent,
                    data: data
                )
            }
        }
    }

    // MARK: - Helpers

    private var accountAtHost: String {
        config.account.isEmpty ? "web@\(config.baseURL?.absoluteString ?? config.host)" : "\(config.account)@\(config.host)"
    }
}

/// A `.torrent` file handed to the app from outside (Files / Safari /
/// Mail). Carries the raw data so AddTaskView can submit it without
/// re-reading a security-scoped URL that may no longer be valid.
struct PendingTorrentFile: Equatable {
    let name: String
    let data: Data
}
