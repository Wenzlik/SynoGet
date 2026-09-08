import XCTest
import Security
@testable import DropStation

final class WebSessionBridgeTests: XCTestCase {
    private let apiURL = URL(string: "https://nas.example.test:5001/webapi/entry.cgi")!

    private func cookie(_ name: String = "id", value: String = "candidate", domain: String = "nas.example.test",
                        path: String = "/", secure: Bool = true, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
            .secure: secure ? "TRUE" : "FALSE"
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testSameOriginRequiresSchemeHostAndEffectivePort() {
        XCTAssertTrue(WebSessionBridge.sameOrigin(apiURL, URL(string: "https://NAS.example.test:5001/webman/")!))
        for other in ["http://nas.example.test:5001", "https://evil.test:5001", "https://nas.example.test:5002"] {
            XCTAssertFalse(WebSessionBridge.sameOrigin(apiURL, URL(string: other)!))
        }
        XCTAssertTrue(WebSessionBridge.sameOrigin(URL(string: "https://nas.test")!, URL(string: "https://nas.test:443/")!))
    }

    func testCookieFiltersDomainPathExpiryAndTransport() {
        let cookies = [cookie(), cookie(value: "evil", domain: "evil.test"),
                       cookie(value: "expired", expires: Date(timeIntervalSince1970: 1)),
                       cookie(value: "webOnly", path: "/webman"), cookie(value: "prefix", path: "/webap")]
        XCTAssertEqual(WebSessionBridge.applicableCookies(cookies, to: apiURL).map(\.value), ["candidate"])
        XCTAssertNil(WebSessionBridge.session(cookies: [cookie()], apiURL: URL(string: "http://nas.example.test/webapi/entry.cgi")!, token: nil))
    }

    func testDomainCookieDoesNotMatchLookalikeHost() {
        XCTAssertEqual(WebSessionBridge.applicableCookies([cookie(domain: ".example.test")], to: apiURL).count, 1)
        XCTAssertTrue(WebSessionBridge.applicableCookies([cookie(domain: ".example.test")], to: URL(string: "https://badexample.test/webapi/entry.cgi")!).isEmpty)
    }

    func testAmbiguousOrEmptySIDIsRejected() {
        XCTAssertNil(WebSessionBridge.session(cookies: [cookie(), cookie(value: "second", path: "/webapi")], apiURL: apiURL, token: nil))
        XCTAssertNil(WebSessionBridge.session(cookies: [cookie(value: "")], apiURL: apiURL, token: nil))
        XCTAssertNil(WebSessionBridge.session(cookies: [cookie("did")], apiURL: apiURL, token: nil))
    }

    func testSessionCarriesTokenAndAcceptsIdenticalCookieValues() {
        let auth = WebSessionBridge.session(cookies: [cookie(), cookie(path: "/webapi")], apiURL: apiURL, token: "csrf")
        XCTAssertEqual(auth, AuthSession(sid: "candidate", synoToken: "csrf"))
        XCTAssertNil(WebSessionBridge.session(cookies: [cookie()], apiURL: apiURL, token: "")?.synoToken)
    }

    func testSessionAndTokenResponseRoundTrip() throws {
        let auth = AuthSession(sid: "sid", synoToken: "token&+=")
        XCTAssertEqual(try JSONDecoder().decode(AuthSession.self, from: JSONEncoder().encode(auth)), auth)
        XCTAssertNil(try JSONDecoder().decode(AuthSession.self, from: Data(#"{"sid":"legacy"}"#.utf8)).synoToken)
        let response = try JSONDecoder().decode(APIResponse<SynoTokenData>.self, from: Data(#"{"success":true,"data":{"synotoken":"csrf"}}"#.utf8))
        XCTAssertEqual(response.data?.synotoken, "csrf")
        let login = try JSONDecoder().decode(LoginData.self, from: Data(#"{"sid":"sid","synotoken":"csrf"}"#.utf8))
        XCTAssertEqual(login.synotoken, "csrf")
    }

    func testKeychainMigrationAndCleanupKeepSIDAndTokenTogether() throws {
        let key = "web-test-\(UUID())"
        defer { KeychainStorage.deleteSID(for: key) }
        try KeychainStorage.setSID("legacy", for: key)
        XCTAssertEqual(KeychainStorage.authSession(for: key), AuthSession(sid: "legacy"))
        let auth = AuthSession(sid: "web", synoToken: "csrf")
        try KeychainStorage.setAuthSession(auth, for: key)
        XCTAssertEqual(KeychainStorage.authSession(for: key), auth)
        XCTAssertNil(KeychainStorage.sid(for: key))
        KeychainStorage.deleteSID(for: key)
        XCTAssertNil(KeychainStorage.authSession(for: key))
    }
    func testKeychainSessionCookiesAndMetadataDoNotCollide() throws {
        let key = "web-test-\(UUID())"
        defer {
            KeychainStorage.deleteSID(for: key)
            KeychainStorage.deleteCookies(for: key)
            KeychainStorage.deleteSessionMetadata(for: key)
        }
        let auth = AuthSession(sid: "sid", synoToken: "token")
        let cookies = [StoredCookie(cookie: cookie())]
        let metadata = SessionMetadata(baseURL: apiURL.absoluteString, account: "", sessionName: "DSM web", createdAt: Date(), lastValidatedAt: Date())
        try KeychainStorage.setAuthSession(auth, for: key)
        try KeychainStorage.setCookies(cookies, for: key)
        try KeychainStorage.setSessionMetadata(metadata, for: key)
        XCTAssertEqual(KeychainStorage.authSession(for: key), auth)
        XCTAssertEqual(KeychainStorage.cookies(for: key), cookies)
        XCTAssertEqual(KeychainStorage.sessionMetadata(for: key), metadata)
        KeychainStorage.deleteCookies(for: key)
        XCTAssertEqual(KeychainStorage.authSession(for: key), auth)
    }

    func testLegacyKeychainServiceRemainsReadableAndIsRemoved() throws {
        let key = "legacy-test-\(UUID())"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.wenzlik.DropStation",
                                   kSecAttrAccount as String: key, kSecAttrLabel as String: "sid"]
        var attributes = query
        attributes[kSecValueData as String] = Data("legacy".utf8)
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
        defer { KeychainStorage.deleteSID(for: key) }
        XCTAssertEqual(KeychainStorage.authSession(for: key), AuthSession(sid: "legacy"))
        try KeychainStorage.setAuthSession(AuthSession(sid: "new", synoToken: "csrf"), for: key)
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        XCTAssertEqual(KeychainStorage.authSession(for: key)?.synoToken, "csrf")
    }

}
