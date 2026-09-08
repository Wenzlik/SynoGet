import XCTest
@testable import DropStation

private final class AuthMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class AuthSessionRequestTests: XCTestCase {
    private let config = ServerConfig(scheme: .https, host: "auth-tests.invalid", port: 5001, account: "native-user")
    private var preferences: [String: Any] = [:]
    private let preferenceKeys = [RememberSessionSettings.storageKey, PasswordPersistenceSettings.storageKey, "synology.server.config"]

    override func setUp() async throws {
        for key in preferenceKeys { preferences[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(false, forKey: RememberSessionSettings.storageKey)
        UserDefaults.standard.set(false, forKey: PasswordPersistenceSettings.storageKey)
        ServerConfigStore.clear()
    }

    override func tearDown() async throws {
        for key in preferenceKeys {
            if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        AuthMockProtocol.handler = nil
    }

    private func client() async -> SynologyAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMockProtocol.self]
        configuration.httpCookieStorage = nil
        let client = SynologyAPIClient(session: URLSession(configuration: configuration))
        await client.configure(baseURL: config.baseURL!)
        return client
    }

    func testTokenReachesDS1DS2FileStationAndMultipart() async throws {
        let client = await client()
        await client.restoreSession(AuthSession(sid: "sid", synoToken: "csrf&+="))
        AuthMockProtocol.handler = { request in
            let body = AuthMockProtocol.body(request)
            if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart") == true {
                XCTAssertTrue(body.contains("name=\"SynoToken\"\r\n\r\ncsrf&+="))
                XCTAssertTrue(body.contains("name=\"torrent\""))
                XCTAssertTrue(request.url!.query!.contains("_sid=sid"))
            } else { XCTAssertTrue(body.contains("SynoToken=csrf%26%2B%3D")) }
            return #"{"success":true,"data":{"tasks":[],"shares":[]}}"#
        }
        _ = try await client.listTasks()
        try await client.stopTasks(ids: ["task"])
        _ = try await client.listShares()
        try await client.createTask(fileData: Data("torrent".utf8), filename: "test.torrent")
    }

    func testLoginRequestsTokenWithoutLeakingOldTokenAndClearRemovesIt() async throws {
        let client = await client()
        await client.restoreSession(AuthSession(sid: "old", synoToken: "oldToken"))
        AuthMockProtocol.handler = { request in
            let body = AuthMockProtocol.body(request)
            XCTAssertTrue(body.contains("enable_syno_token=yes"))
            XCTAssertFalse(body.contains("SynoToken="))
            return #"{"success":true,"data":{"sid":"new","synotoken":"newToken"}}"#
        }
        let result = try await client.login(account: "user", password: "password")
        XCTAssertEqual(result, AuthSession(sid: "new", synoToken: "newToken"))
        await client.clearSession()
        await client.restoreSession(sid: "legacy")
        AuthMockProtocol.handler = { request in
            XCTAssertFalse(AuthMockProtocol.body(request).contains("SynoToken="))
            return #"{"success":true,"data":{"tasks":[]}}"#
        }
        _ = try await client.listTasks()
    }

    func testWebProbeRejects105AndClearsCandidate() async {
        let client = await client()
        let store = SessionStore(client: client)
        AuthMockProtocol.handler = { _ in #"{"success":false,"error":{"code":105}}"# }
        await store.completeWebSignIn(config: config, auth: AuthSession(sid: "web", synoToken: "csrf"), cookies: [])
        guard case .sessionUnauthorized = store.state else { return XCTFail("Expected recovery") }
        XCTAssertTrue(store.isWebRecovery)
        XCTAssertFalse(store.canRetryWebValidation)
        let loggedIn = await client.isLoggedIn
        XCTAssertFalse(loggedIn)
        XCTAssertEqual(store.config.account, "")
    }

    func testWebTransientFailureRetriesWithoutRepeatingLogin() async {
        let client = await client()
        let store = SessionStore(client: client)
        AuthMockProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await store.completeWebSignIn(config: config, auth: AuthSession(sid: "web", synoToken: "csrf"), cookies: [])
        XCTAssertTrue(store.canRetryWebValidation)
        guard case .sessionUnauthorized = store.state else { return XCTFail("Expected retry") }
        AuthMockProtocol.handler = { request in
            XCTAssertTrue(AuthMockProtocol.body(request).contains("SynoToken=csrf"))
            return #"{"success":true,"data":{"tasks":[]}}"#
        }
        await store.retryWebValidation()
        XCTAssertEqual(store.state, .loggedIn)
        XCTAssertFalse(store.canRetryWebValidation)
        await store.logout()
    }

    func testWebSessionColdRestoreWorksWithoutNativeUsername() async throws {
        UserDefaults.standard.set(true, forKey: RememberSessionSettings.storageKey)
        let client = await client()
        let store = SessionStore(client: client)
        AuthMockProtocol.handler = { _ in #"{"success":true,"data":{"tasks":[]}}"# }
        await store.completeWebSignIn(config: config, auth: AuthSession(sid: "web", synoToken: "csrf"), cookies: [])
        let restored = SessionStore(client: await self.client())
        AuthMockProtocol.handler = { request in
            XCTAssertTrue(AuthMockProtocol.body(request).contains("SynoToken=csrf"))
            return #"{"success":true,"data":{"tasks":[]}}"#
        }
        await restored.restoreOnLaunch()
        XCTAssertEqual(restored.state, .loggedIn)
        XCTAssertEqual(restored.config.account, "")
        restored.setRememberSession(false)
        XCTAssertNil(KeychainStorage.authSession(for: "web@\(config.baseURL!.absoluteString)"))
        await restored.logout()
    }

    func testWrongOTPAndTransportFailureKeepChallengeAndCredentials() async {
        let client = await client()
        let store = SessionStore(client: client)
        AuthMockProtocol.handler = { _ in #"{"success":false,"error":{"code":403}}"# }
        await store.login(config: config, password: "password")
        XCTAssertEqual(store.state, .twoFactorRequired)
        AuthMockProtocol.handler = { _ in #"{"success":false,"error":{"code":404}}"# }
        await store.submitOTP("123456")
        XCTAssertEqual(store.state, .twoFactorRequired)
        XCTAssertNotNil(store.otpError)
        AuthMockProtocol.handler = { _ in throw URLError(.timedOut) }
        await store.submitOTP("234567")
        XCTAssertEqual(store.state, .twoFactorRequired)
        XCTAssertFalse(store.isVerifyingOTP)
        AuthMockProtocol.handler = { request in
            XCTAssertTrue(AuthMockProtocol.body(request).contains("passwd=password"))
            return #"{"success":true,"data":{"sid":"verified"}}"#
        }
        await store.submitOTP("345678")
        XCTAssertEqual(store.state, .loggedIn)
        AuthMockProtocol.handler = { _ in #"{"success":true}"# }
        await store.logout()
    }
}
