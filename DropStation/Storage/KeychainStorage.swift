import Foundation
import Security

/// Minimal Keychain wrapper. Stores credential types in separate service namespaces:
///   - Password    (account = NAS username)
///   - SID         (account = "<username>@<host>")
///   - Cookies     (account = "<username>@<host>", JSON-encoded [StoredCookie])
///   - SessionMeta (account = "<username>@<host>", JSON-encoded SessionMetadata)
///   - CertPin     (account = "<host>", SHA-256 fingerprint of a user-trusted
///                  self-signed certificate — keyed by host, not account, since
///                  a cert belongs to the server)
/// Labels are retained for reading legacy records; they are not unique keys.
enum KeychainStorage {
    private static let service = "com.wenzlik.DropStation"

    enum Kind: String {
        case password = "password"
        case sid = "sid"
        case authSession = "authSession"
        case cookies = "cookies"
        case sessionMeta = "sessionMeta"
        case certPin = "certPin"
    }

    // MARK: - Password

    static func setPassword(_ password: String, for account: String) throws {
        try store(value: password, kind: .password, account: account)
    }

    static func password(for account: String) -> String? {
        load(kind: .password, account: account)
    }

    static func deletePassword(for account: String) {
        remove(kind: .password, account: account)
    }

    // MARK: - SID

    static func setSID(_ sid: String, for accountAtHost: String) throws {
        try store(value: sid, kind: .sid, account: accountAtHost)
    }

    static func sid(for accountAtHost: String) -> String? {
        load(kind: .sid, account: accountAtHost)
    }

    static func deleteSID(for accountAtHost: String) {
        remove(kind: .authSession, account: accountAtHost)
        remove(kind: .sid, account: accountAtHost)
    }

    /// One Keychain record keeps the token paired with its SID. Legacy SID-only
    /// installs remain readable; replacement removes the legacy copy.
    static func setAuthSession(_ session: AuthSession, for key: String) throws {
        let data = try JSONEncoder().encode(session)
        try store(value: String(decoding: data, as: UTF8.self), kind: .authSession, account: key)
        remove(kind: .sid, account: key)
    }

    static func authSession(for key: String) -> AuthSession? {
        if let json = load(kind: .authSession, account: key) {
            return try? JSONDecoder().decode(AuthSession.self, from: Data(json.utf8))
        }
        return sid(for: key).map { AuthSession(sid: $0) }
    }

    // MARK: - Cookies

    /// Persist the Secure SignIn web session cookies. JSON-encoded so the
    /// generic password storage primitive keeps working. Encoding errors
    /// surface as `KeychainError.encoding` rather than crashing — a
    /// cookie that can't be encoded just means session restore won't be
    /// available next launch, not that the current session breaks.
    static func setCookies(_ cookies: [StoredCookie], for accountAtHost: String) throws {
        do {
            let data = try JSONEncoder().encode(cookies)
            guard let json = String(data: data, encoding: .utf8) else {
                throw KeychainError.encoding
            }
            try store(value: json, kind: .cookies, account: accountAtHost)
        } catch let error as KeychainError {
            throw error
        } catch {
            throw KeychainError.encoding
        }
    }

    static func cookies(for accountAtHost: String) -> [StoredCookie]? {
        guard let json = load(kind: .cookies, account: accountAtHost),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([StoredCookie].self, from: data)
    }

    static func deleteCookies(for accountAtHost: String) {
        remove(kind: .cookies, account: accountAtHost)
    }

    // MARK: - Session metadata

    /// Persist sidecar info (createdAt / lastValidatedAt / sessionName) for
    /// the SID under the same account-at-host key. JSON-encoded for the
    /// generic password slot. Encoding failures surface as
    /// `KeychainError.encoding` — the SID itself is unaffected, we just
    /// lose the staleness hint and the next launch will run a fresh
    /// validation probe regardless.
    static func setSessionMetadata(_ metadata: SessionMetadata, for accountAtHost: String) throws {
        do {
            let data = try JSONEncoder().encode(metadata)
            guard let json = String(data: data, encoding: .utf8) else {
                throw KeychainError.encoding
            }
            try store(value: json, kind: .sessionMeta, account: accountAtHost)
        } catch let error as KeychainError {
            throw error
        } catch {
            throw KeychainError.encoding
        }
    }

    static func sessionMetadata(for accountAtHost: String) -> SessionMetadata? {
        guard let json = load(kind: .sessionMeta, account: accountAtHost),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionMetadata.self, from: data)
    }

    static func deleteSessionMetadata(for accountAtHost: String) {
        remove(kind: .sessionMeta, account: accountAtHost)
    }

    // MARK: - Certificate pin

    /// Persist a user-trusted self-signed certificate fingerprint,
    /// keyed by **host** (a certificate is a property of the server,
    /// not the account — distinct from the SID/cookie/metadata keys
    /// which use "<username>@<host>"). The trust coordinator accepts
    /// a self-signed cert only when its leaf fingerprint matches the
    /// stored value.
    static func setPinnedCertFingerprint(_ fingerprint: String, for host: String) throws {
        try store(value: fingerprint, kind: .certPin, account: host)
    }

    static func pinnedCertFingerprint(for host: String) -> String? {
        load(kind: .certPin, account: host)
    }

    static func deletePinnedCertFingerprint(for host: String) {
        remove(kind: .certPin, account: host)
    }

    // MARK: - Common

    /// Generic-password uniqueness is service + account, NOT label. Older
    /// builds silently collided when writing SID, cookies and metadata for
    /// the same account. Namespace the service; read legacy records by label.
    private static func query(kind: Kind, account: String, legacy: Bool = false) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacy ? service : "\(service).\(kind.rawValue)",
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: kind.rawValue
        ]
    }

    private static func store(value: String, kind: Kind, account: String) throws {
        let identity = query(kind: kind, account: account)
        let valueAttributes = [kSecValueData as String: Data(value.utf8)]
        let updateStatus = SecItemUpdate(identity as CFDictionary, valueAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var attributes = identity
            attributes[kSecValueData as String] = Data(value.utf8)
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.status(updateStatus)
        }
        // Only remove the old value after the new value has been stored.
        SecItemDelete(query(kind: kind, account: account, legacy: true) as CFDictionary)
    }

    private static func load(kind: Kind, account: String) -> String? {
        for legacy in [false, true] {
            var lookup = query(kind: kind, account: account, legacy: legacy)
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    private static func remove(kind: Kind, account: String) {
        for legacy in [false, true] {
            SecItemDelete(query(kind: kind, account: account, legacy: legacy) as CFDictionary)
        }
    }

    enum KeychainError: Error {
        case status(OSStatus)
        case encoding
    }
}
