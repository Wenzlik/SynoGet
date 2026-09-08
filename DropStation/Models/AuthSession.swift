import Foundation

/// SID and CSRF context belong to the same login and must travel together.
struct AuthSession: Codable, Equatable {
    let sid: String
    var synoToken: String? = nil
}

/// Only cookies applicable to the actual API URL can supply an API SID.
/// Reject ambiguous IDs rather than selecting an arbitrary account/session.
enum WebSessionBridge {
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
    }

    static func applicableCookies(_ cookies: [HTTPCookie], to url: URL, now: Date = Date()) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let bareDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let domainMatches = host == bareDomain || (domain.hasPrefix(".") && host.hasSuffix("." + bareDomain))
            let path = url.path.isEmpty ? "/" : url.path
            let cookiePath = cookie.path
            let pathMatches = path == cookiePath || (path.hasPrefix(cookiePath)
                && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
            return domainMatches && pathMatches
                && (!cookie.isSecure || url.scheme?.lowercased() == "https")
                && (cookie.expiresDate.map { $0 > now } ?? true)
        }
    }

    static func session(cookies: [HTTPCookie], apiURL: URL, token: String?) -> AuthSession? {
        let ids = Set(applicableCookies(cookies, to: apiURL).filter { $0.name == "id" }.map(\.value))
        guard ids.count == 1, let sid = ids.first, !sid.isEmpty else { return nil }
        return AuthSession(sid: sid, synoToken: token?.isEmpty == false ? token : nil)
    }
}

struct SynoTokenData: Decodable {
    let synotoken: String?
}
