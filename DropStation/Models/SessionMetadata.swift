import Foundation

/// Sidecar info we persist alongside the Keychain SID so the app can
/// answer "do I still need to bother the user for OTP?" on launch and
/// on foreground returns without round-tripping the server every time.
///
/// `lastValidatedAt` is the timestamp of the most recent successful
/// Download Station API call we've made with this SID. The foreground
/// probe uses it to throttle silent revalidations — if we've talked to
/// the NAS in the last few minutes the SID is almost certainly still
/// good and we skip the network round trip.
///
/// `sessionName` records the login source ("DownloadStation" for native
/// login, "DSM web" for the web bridge). Only a successful API probe proves
/// which endpoints a web session can access.
struct SessionMetadata: Codable, Equatable {
    let baseURL: String
    let account: String
    let sessionName: String
    let createdAt: Date
    var lastValidatedAt: Date

    static let downloadStationSession = "DownloadStation"
}

/// UserDefaults-backed preference for whether the app should persist
/// the Download Station SID across launches.
///
/// Default is ON: a returning user lands straight on the task list
/// without a fresh OTP challenge as long as the saved SID still
/// validates. Users who prefer the more conservative "fresh sign-in
/// every cold start" behaviour can flip it OFF in Settings; when OFF,
/// SID + session metadata are not written to the Keychain and any
/// existing entries are removed on the next logout.
enum RememberSessionSettings {
    static let storageKey = "auth.rememberSession"

    /// Default true. Treat "no value yet" as on so the first launch
    /// after install gets the smooth flow without forcing the user
    /// into Settings to enable it.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }
}

/// UserDefaults-backed preference for whether the app should persist the
/// account password in the Keychain.
///
/// Default is ON. When enabled, a successful sign-in stores the password
/// (encrypted, device-bound, keyed by username) so that after a session
/// expiry the app can re-authenticate on its own and prompt the user for
/// **only** the rotating OTP code — never the password again. The OTP
/// itself is time-based and can't be cached, so it's always required when
/// 2FA is on.
///
/// Switching OFF deletes any saved password immediately. An explicit
/// "Sign out" / "Forget this device" always clears it regardless of this
/// setting.
enum PasswordPersistenceSettings {
    static let storageKey = "auth.rememberPassword"

    /// Default true — mirrors `RememberSessionSettings` so a returning
    /// user gets the smooth OTP-only flow without a Settings detour.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }
}

