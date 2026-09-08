import Foundation
import Security
import CryptoKit

/// SHA-256 fingerprint of a DER-encoded certificate, formatted as
/// colon-separated uppercase hex pairs ("AB:CD:…"). This is the
/// format browsers and Keychain Access show, so it's recognisable
/// when we ask a user to confirm their NAS's self-signed
/// certificate.
enum CertificateFingerprint {
    static func sha256Hex(of der: Data) -> String {
        SHA256.hash(data: der)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}

/// Keychain-backed store of user-trusted self-signed certificate
/// fingerprints, keyed by host. A pinned fingerprint means "the
/// user explicitly trusted this exact certificate for this host" —
/// the trust coordinator accepts a self-signed cert only when the
/// presented leaf's fingerprint matches the pin. A *changed*
/// fingerprint (cert rotated, or a MITM) won't match, so it
/// re-prompts instead of silently trusting.
enum CertPinStore {
    static func pinnedFingerprint(for host: String) -> String? {
        KeychainStorage.pinnedCertFingerprint(for: host)
    }

    static func pin(_ fingerprint: String, for host: String) {
        try? KeychainStorage.setPinnedCertFingerprint(fingerprint, for: host)
    }

    static func unpin(host: String) {
        KeychainStorage.deletePinnedCertFingerprint(for: host)
    }
}

/// `URLSession` delegate implementing trust-on-first-use for
/// self-signed NAS certificates (DSM ships a self-signed cert by
/// default, so this is the common-case Synology deployment).
///
/// Decision flow on a server-trust challenge:
///
///   1. **Validates against the system trust store** (a real CA —
///      Let's Encrypt via Synology DDNS, etc.) → accept normally.
///   2. **Self-signed / untrusted, fingerprint matches a user pin**
///      → accept (the user trusted this exact cert before).
///   3. **Self-signed / untrusted, no matching pin** → record the
///      (host, fingerprint) and reject the challenge. The API
///      client turns the resulting failure into
///      `APIError.serverTrust`, which the UI (Phase B.2) routes to
///      a "trust this server?" prompt that, on confirm, pins the
///      fingerprint and retries.
///
/// Fails closed: if the leaf certificate can't be read, the
/// challenge is rejected rather than blindly trusted.
///
/// `@unchecked Sendable` because the delegate callback runs on the
/// URLSession delegate queue while the API client (an actor) reads
/// `takeRejectedFingerprint` from its own executor — all shared
/// mutable state is guarded by `lock`.
final class ServerTrustCoordinator: NSObject, URLSessionDelegate, @unchecked Sendable {
    /// Most recent rejected (untrusted, unpinned) certificate per
    /// host. Written by the delegate callback, drained by the API
    /// client after a request fails so it can build
    /// `APIError.serverTrust(host:fingerprint:)`.
    private let lock = NSLock()
    private var rejected: [String: String] = [:]

    /// Returns and clears any recorded rejection for `host`. Called
    /// by the API client in its transport-error catch path.
    func takeRejectedFingerprint(for host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return rejected.removeValue(forKey: host)
    }

    private func recordRejection(host: String, fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        rejected[host] = fingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    /// Shared by URLSession and the DSM web sheet so trust decisions agree.
    func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            // Not a server-trust challenge (client cert, basic auth,
            // …). We don't do those — let the system handle it.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host

        // 1. Real CA chain → accept normally.
        var trustError: CFError?
        if SecTrustEvaluateWithError(serverTrust, &trustError) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        // 2. Self-signed. Read the leaf fingerprint; fail closed if
        //    we can't.
        guard let fingerprint = Self.leafFingerprint(of: serverTrust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 3. Accept iff the user pinned this exact fingerprint.
        if let pinned = CertPinStore.pinnedFingerprint(for: host), pinned == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        // 4. Untrusted + unpinned → record + reject. The client
        //    surfaces APIError.serverTrust; the UI offers to pin.
        recordRejection(host: host, fingerprint: fingerprint)
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    /// SHA-256 fingerprint of the leaf certificate in a server
    /// trust. `SecTrustCopyCertificateChain` (iOS 15+) returns the
    /// chain leaf-first.
    private static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return CertificateFingerprint.sha256Hex(of: der)
    }
}
