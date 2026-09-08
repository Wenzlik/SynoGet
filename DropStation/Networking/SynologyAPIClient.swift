import Foundation

/// Async/await client for the Synology Download Station and FileStation Web APIs.
///
/// Endpoints used: `SYNO.API.Auth`, `SYNO.DownloadStation.Task`,
/// `SYNO.FileStation.List`. See Synology's published Download Station and
/// DSM Login Web API guides (linked from the project README) for the wire format.
actor SynologyAPIClient {
    private let session: URLSession
    /// Handles self-signed-certificate trust (trust-on-first-use +
    /// pinning). Retained by `session` as its delegate; we keep our
    /// own reference to drain rejected-certificate records after a
    /// request fails so we can surface `APIError.serverTrust`.
    private let trustCoordinator: ServerTrustCoordinator
    private var baseURL: URL?
    private var authSession: AuthSession?
    private var sid: String? { authSession?.sid }

    init() {
        let coordinator = ServerTrustCoordinator()
        let configuration = URLSessionConfiguration.default
        // Share the global cookie jar so the Secure SignIn cookie
        // flow (clearAuthCookies / cookie restore) keeps working —
        // it operates on HTTPCookieStorage.shared.
        configuration.httpCookieStorage = .shared
        configuration.httpCookieAcceptPolicy = .always
        self.trustCoordinator = coordinator
        self.session = URLSession(configuration: configuration, delegate: coordinator, delegateQueue: nil)
    }

    /// Test seam — inject a session without the trust delegate. Used
    /// only where no network calls are made (e.g. the view-model
    /// derivation tests). Production always goes through `init()`.
    init(session: URLSession) {
        self.session = session
        self.trustCoordinator = ServerTrustCoordinator()
    }

    /// Maps a thrown transport error to `APIError`, upgrading it to
    /// `.serverTrust` when the trust coordinator rejected the host's
    /// certificate during this request. Centralised so both request
    /// paths (postForm + multipart create) classify identically.
    private func mapTransportError(_ error: Error, requestURL: URL?) -> APIError {
        if let host = requestURL?.host,
           let fingerprint = trustCoordinator.takeRejectedFingerprint(for: host) {
            return .serverTrust(host: host, fingerprint: fingerprint)
        }
        return .transport(error)
    }

    var isLoggedIn: Bool { sid != nil }

    func configure(baseURL: URL) {
        if self.baseURL != baseURL { authSession = nil }
        self.baseURL = baseURL
    }

    /// Restore a previously-acquired SID without going through `login`.
    /// Caller is responsible for verifying the session is still valid (e.g. by calling `listTasks`).
    func restoreSession(sid: String) {
        self.authSession = AuthSession(sid: sid)
    }

    func restoreSession(_ authSession: AuthSession) {
        self.authSession = authSession
    }

    func clearSession() {
        self.authSession = nil
    }

    /// Drop every cookie DSM has set for our base URL. The relevant one is
    /// `did` (device id) — DSM hands it out after a successful 2FA and
    /// honours it on subsequent `auth.cgi` calls by skipping the 2FA
    /// challenge entirely. Wiping the jar guarantees the next login is
    /// treated as a brand-new device.
    ///
    /// Safe to call mid-session — we identify our session via the `_sid`
    /// URL query parameter, never via cookies, so the active SID is
    /// untouched. Callers: form-driven login, `forgetDevice`, and the
    /// "Re-authenticate now" affordance.
    func clearAuthCookies() {
        guard let baseURL else { return }
        guard let host = baseURL.host else { return }
        let storage = HTTPCookieStorage.shared
        // Match cookies by domain rather than `cookies(for:)` — that helper
        // also filters by path, and we'd miss cookies set with a more
        // specific path (e.g. `/webapi`). We want every cookie this host
        // has set us, regardless of which endpoint it came from.
        let toRemove = storage.cookies?.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        } ?? []
        for cookie in toRemove {
            storage.deleteCookie(cookie)
        }
    }

    // MARK: - Auth

    typealias LoginResult = AuthSession

    /// SYNO.API.Auth login (DownloadStation session, API version 6).
    /// Credentials are sent as POST form data so they do not end up in server access logs.
    ///
    /// 2FA: pass `otpCode` when the server has already demanded one (the previous
    /// attempt returned 403). Synology Secure SignIn push approval is intentionally
    /// not wired up — the public `auth.cgi` endpoint can't trigger it, and the
    /// `enable_device_token` flow that would mint a long-lived device id
    /// suppresses the push entirely, so we keep the call minimal.
    /// Query DSM for which APIs are available + their paths + accepted
    /// version range. Useful for diagnostics — different DSM versions
    /// expose different sub-APIs and method versions; logging this
    /// helps when a request fails for a reason that turns out to be
    /// "this endpoint isn't on your DSM build".
    func apiInfo(query: String = "SYNO.DownloadStation.*,SYNO.API.Auth") async throws -> [String: APIInfoEntry] {
        guard let baseURL else { throw APIError.invalidURL }
        let url = baseURL.appendingPathComponent("/webapi/query.cgi")
        let params: [String: String] = [
            "api": "SYNO.API.Info",
            "version": "1",
            "method": "query",
            "query": query
        ]
        DSLog.auth("apiInfo query=\(query)")
        let response: APIResponse<APIInfoData> = try await postForm(url: url, params: params)
        try ensureSuccess(response)
        return response.data?.entries ?? [:]
    }

    @discardableResult
    func login(
        account: String,
        password: String,
        otpCode: String? = nil
    ) async throws -> LoginResult {
        guard let baseURL else { throw APIError.invalidURL }

        var params: [String: String] = [
            "api": "SYNO.API.Auth",
            "version": "6",
            "method": "login",
            "account": account,
            "passwd": password,
            "session": "DownloadStation",
            "format": "sid",
            "enable_syno_token": "yes"
        ]
        if let otpCode { params["otp_code"] = otpCode }

        let url = baseURL.appendingPathComponent("/webapi/auth.cgi")
        let response: APIResponse<LoginData> = try await postForm(url: url, params: params)
        try ensureSuccess(response)
        guard let data = response.data, !data.sid.isEmpty else {
            throw APIError.synology(code: -1, message: "Login succeeded but no session id returned.")
        }
        let auth = AuthSession(sid: data.sid, synoToken: data.synotoken)
        self.authSession = auth
        return auth
    }

    func logout() async throws {
        guard let baseURL, let sid else { return }
        let url = baseURL.appendingPathComponent("/webapi/auth.cgi")
        let params: [String: String] = [
            "api": "SYNO.API.Auth",
            "version": "6",
            "method": "logout",
            "_sid": sid
        ]
        _ = try? await postForm(url: url, params: params) as APIResponse<EmptyData>
        self.authSession = nil
    }

    // MARK: - Tasks

    func listTasks() async throws -> [DownloadTask] {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }

        let url = baseURL.appendingPathComponent("/webapi/DownloadStation/task.cgi")
        let params: [String: String] = [
            "api": "SYNO.DownloadStation.Task",
            "version": "1",
            "method": "list",
            // detail = create_time + completed_time + destination + priority + peer
            // counts. We use create_time + completed_time for sort-by-date in the
            // list UI; the rest is shown on the Detail screen but cheap to include.
            "additional": "transfer,detail",
            "_sid": sid
        ]
        let response: APIResponse<TaskListData> = try await postForm(url: url, params: params)
        try ensureSuccess(response, context: .task)
        return response.data?.tasks ?? []
    }

    /// Create a download task from a URI (magnet:, http:, ftp:, https:).
    /// `destination` is the path **without** a leading slash, starting with a shared folder
    /// (e.g. "Downloads/Movies"). Pass `nil` to use the server's configured default.
    func createTask(uri: String, destination: String? = nil) async throws {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }

        let url = baseURL.appendingPathComponent("/webapi/DownloadStation/task.cgi")
        // Version 3+ is required for `uri` (per the Synology Download Station API
        // spec) and version 2+ for `destination`. Sending these with the older
        // version=1 we used previously triggers Synology error 101 "Invalid
        // parameter" on DSM 7 builds.
        var params: [String: String] = [
            "api": "SYNO.DownloadStation.Task",
            "version": "3",
            "method": "create",
            "uri": uri,
            "_sid": sid
        ]
        if let destination, !destination.isEmpty { params["destination"] = destination }
        let response: APIResponse<EmptyData> = try await postForm(url: url, params: params)
        try ensureSuccess(response)
    }

    /// Create a download task from a local .torrent / .nzb file.
    ///
    /// Uses the DSM 7 **DownloadStation2** task endpoint, not the legacy
    /// `task.cgi` one — the documented `SYNO.DownloadStation.Task` create
    /// method just keeps returning 101 Invalid parameter for file uploads on
    /// recent DSM builds, regardless of multipart layout (we tried both
    /// option (a) and option (b) from the spec). The DS2 endpoint at
    /// `/webapi/entry.cgi` is what DSM's own web UI uses, and it accepts:
    ///
    ///   - field `torrent` containing the file's binary data
    ///   - a sidecar `file` field whose value is a JSON list of which fields
    ///     are files (here just `["torrent"]`)
    ///   - `mtime` (epoch milliseconds) and `size` of the upload as strings
    ///
    /// Reference: dvcol/synology-download (`SynologyDownload2Service.createTask`).
    func createTask(fileData: Data, filename: String, destination: String? = nil) async throws {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }

        // DS2 entry.cgi reads `_sid` from the URL query, not from the multipart
        // body — passing it in the body returns 119 SID not found even when the
        // session is valid for every other endpoint we use.
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/webapi/entry.cgi"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "_sid", value: sid)]
        guard let url = components.url else { throw APIError.invalidURL }

        // DS2 task.create has three required fields beyond the call envelope:
        //   type         — "file" for an uploaded .torrent / .nzb, "url" for a URI
        //   destination  — path string; empty string means "use the default folder"
        //   create_list  — whether to prompt for per-file selection after creation
        var fields: [(String, String)] = [
            ("api", "SYNO.DownloadStation2.Task"),
            ("method", "create"),
            ("version", "2"),
            ("type", "\"file\""),
            ("destination", "\"\(destination ?? "")\""),
            ("create_list", "false"),
            ("mtime", String(Int(Date().timeIntervalSince1970 * 1000))),
            ("size", String(fileData.count)),
            ("file", "[\"torrent\"]")
        ]

        if let token = authSession?.synoToken { fields.append(("SynoToken", token)) }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            boundary: boundary,
            fields: fields,
            fileFieldName: "torrent",
            filename: filename,
            fileData: fileData
        )

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw APIError.http(http.statusCode)
            }
            let decoded = try JSONDecoder().decode(APIResponse<EmptyData>.self, from: data)
            try ensureSuccess(decoded, context: .task)
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            throw APIError.decoding(error)
        } catch {
            throw mapTransportError(error, requestURL: request.url)
        }
    }

    /// Get the full detail object for a single task. Pulls down detail, transfer, file
    /// (BT only) and tracker (BT only) fields in one call.
    func getTaskInfo(id: String) async throws -> DownloadTask {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }

        let url = baseURL.appendingPathComponent("/webapi/DownloadStation/task.cgi")
        let params: [String: String] = [
            "api": "SYNO.DownloadStation.Task",
            "version": "1",
            "method": "getinfo",
            "id": id,
            "additional": "detail,transfer,file,tracker",
            "_sid": sid
        ]
        let response: APIResponse<TaskListData> = try await postForm(url: url, params: params)
        try ensureSuccess(response, context: .task)
        guard let task = response.data?.tasks.first else {
            throw APIError.synology(code: 404, message: "Task not found.")
        }
        return task
    }

    /// Stop an active task: transition it to the documented `finished` status
    /// without deleting it. This is what DSM web's "End" button does.
    ///
    /// Uses the DS2 endpoint `SYNO.DownloadStation2.Task.Complete` with method
    /// `start` (the API names the method "start" because it kicks off the
    /// background completion process; despite the name it ends the task).
    /// The legacy DS1 task.cgi has no equivalent.
    func stopTasks(ids: [String]) async throws {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }
        guard !ids.isEmpty else { return }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("/webapi/entry.cgi"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "_sid", value: sid)]
        guard let url = components.url else { throw APIError.invalidURL }

        // id is a JSON array of strings, matching how dvcol/synology-download
        // wires its DS2 calls — DS2 endpoints uniformly expect JSON values.
        let idJSON = "[" + ids.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let params: [String: String] = [
            "api": "SYNO.DownloadStation2.Task.Complete",
            "method": "start",
            "version": "1",
            "id": idJSON
        ]
        let response: APIResponse<EmptyData> = try await postForm(url: url, params: params)
        try ensureSuccess(response, context: .task)
    }

    func pauseTasks(ids: [String]) async throws {
        try await taskAction(method: "pause", ids: ids)
    }

    func resumeTasks(ids: [String]) async throws {
        try await taskAction(method: "resume", ids: ids)
    }

    private func taskAction(method: String, ids: [String]) async throws {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }
        guard !ids.isEmpty else { return }

        let url = baseURL.appendingPathComponent("/webapi/DownloadStation/task.cgi")
        let params: [String: String] = [
            "api": "SYNO.DownloadStation.Task",
            "version": "1",
            "method": method,
            "id": ids.joined(separator: ","),
            "_sid": sid
        ]
        let response: APIResponse<EmptyData> = try await postForm(url: url, params: params)
        try ensureSuccess(response, context: .task)
    }

    // MARK: - Priority (BT only)

    /// Change the overall priority of a BT task. DS2 endpoint, `Task.BT` API,
    /// `method=set`. Synology only accepts low/normal/high here — the `auto`
    /// state shown in `additional=detail` responses is a default, not a
    /// user-selectable value.
    func setTaskPriority(taskId: String, priority: TaskPriority) async throws {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("/webapi/entry.cgi"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "_sid", value: sid)]
        guard let url = components.url else { throw APIError.invalidURL }

        let params: [String: String] = [
            "api": "SYNO.DownloadStation2.Task.BT",
            "method": "set",
            "version": "2",
            "task_id": "\"\(taskId)\"",
            "priority": "\"\(priority.rawValue)\""
        ]
        let response: APIResponse<EmptyData> = try await postForm(url: url, params: params)
        try ensureSuccess(response, context: .task)
    }

    /// Change per-file priority (and the "wanted" flag) inside a BT torrent.
    /// DS2 endpoint, `Task.BT.File` API, `method=set`. `indices` are positions
    /// in the torrent's file list as returned by `additional=file` on a list
    /// or getinfo call — Synology preserves this ordering across calls.
    func setFilePriorities(
        taskId: String,
        indices: [Int],
        priority: FilePriority
    ) async throws {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }
        guard !indices.isEmpty else { return }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("/webapi/entry.cgi"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "_sid", value: sid)]
        guard let url = components.url else { throw APIError.invalidURL }

        let indexJSON = "[" + indices.map(String.init).joined(separator: ",") + "]"
        var params: [String: String] = [
            "api": "SYNO.DownloadStation2.Task.BT.File",
            "method": "set",
            "version": "2",
            "task_id": "\"\(taskId)\"",
            "index": indexJSON,
            "wanted": priority.wanted ? "true" : "false"
        ]
        // Only send `priority` when the file is being kept; for skip it's
        // meaningless and some DSM builds reject the combination.
        if let p = priority.taskPriority {
            params["priority"] = "\"\(p.rawValue)\""
        }
        let response: APIResponse<EmptyData> = try await postForm(url: url, params: params)
        try ensureSuccess(response, context: .task)
    }

    // MARK: - File Station (folder picker)

    /// List shared folders the logged-in user can access. Returned paths look like
    /// "/Downloads", "/video" — suitable for direct use as the next `listFolders` argument.
    /// The DownloadStation SID is reused; FileStation does not require a separate login.
    func listShares() async throws -> [FileNode] {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }

        let url = baseURL.appendingPathComponent("/webapi/entry.cgi")
        let params: [String: String] = [
            "api": "SYNO.FileStation.List",
            "version": "2",
            "method": "list_share",
            "_sid": sid
        ]
        let response: APIResponse<FileStationShareList> = try await postForm(url: url, params: params)
        try ensureSuccess(response, context: .task)
        return response.data?.shares ?? []
    }

    /// Free space (bytes) on the volume hosting the user's shared
    /// folders. Reuses the already-permitted `SYNO.FileStation.List`
    /// `list_share` endpoint with `additional=["volume_status"]` —
    /// no new permission surface beyond what the destination picker
    /// already needs. Returns the largest per-share free space (see
    /// `ShareVolumeList.headlineFreeBytes`); `nil` when DSM reports
    /// no volume_status. Decorative — the dashboard treats a nil /
    /// throwing result as "free disk unknown" and shows nothing.
    func volumeFreeSpace() async throws -> Int64? {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }

        let url = baseURL.appendingPathComponent("/webapi/entry.cgi")
        let params: [String: String] = [
            "api": "SYNO.FileStation.List",
            "version": "2",
            "method": "list_share",
            // FileStation expects `additional` as a JSON-encoded
            // array (unlike DownloadStation.Task's comma form).
            "additional": "[\"volume_status\"]",
            "_sid": sid
        ]
        let response: APIResponse<ShareVolumeList> = try await postForm(url: url, params: params)
        try ensureSuccess(response, context: .task)
        return response.data?.headlineFreeBytes
    }

    /// List folders inside a path. `path` must start with a shared folder, e.g. "/Downloads".
    /// Only directories are returned (`filetype=dir`).
    func listFolders(in path: String) async throws -> [FileNode] {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }

        let url = baseURL.appendingPathComponent("/webapi/entry.cgi")
        let params: [String: String] = [
            "api": "SYNO.FileStation.List",
            "version": "2",
            "method": "list",
            "folder_path": path,
            "filetype": "dir",
            "_sid": sid
        ]
        let response: APIResponse<FileStationFileList> = try await postForm(url: url, params: params)
        try ensureSuccess(response, context: .task)
        return response.data?.files ?? []
    }

    /// Delete a task.
    /// - Parameters:
    ///   - id: Task ID returned by Synology.
    ///   - keepPartialFiles: When `true`, Synology marks any partially-downloaded
    ///     files as "force complete" and leaves them on disk. When `false`
    ///     (default), the partial files are removed along with the task. Maps
    ///     to the API's `force_complete` parameter, which the Synology spec
    ///     describes as "force to move uncompleted download files".
    func deleteTask(id: String, keepPartialFiles: Bool = false) async throws {
        guard let baseURL else { throw APIError.invalidURL }
        guard let sid else { throw APIError.notLoggedIn }

        let url = baseURL.appendingPathComponent("/webapi/DownloadStation/task.cgi")
        let params: [String: String] = [
            "api": "SYNO.DownloadStation.Task",
            "version": "1",
            "method": "delete",
            "id": id,
            "force_complete": keepPartialFiles ? "true" : "false",
            "_sid": sid
        ]
        let response: APIResponse<EmptyData> = try await postForm(url: url, params: params)
        try ensureSuccess(response, context: .task)
    }

    // MARK: - HTTP

    private func ensureSuccess<T>(_ response: APIResponse<T>, context: SynologyErrorCode.Context = .auth) throws {
        guard !response.success else { return }
        let code = response.error?.code ?? -1
        throw APIError.synology(code: code, message: SynologyErrorCode.message(for: code, context: context))
    }

    /// Build a multipart/form-data body where every `fields` entry becomes a regular
    /// form-data part and the file is appended as the final part (DS2 spec requires
    /// the file part to come last so the upload handler picks it up correctly).
    private func multipartBody(
        boundary: String,
        fields: [(String, String)],
        fileFieldName: String,
        filename: String,
        fileData: Data
    ) -> Data {
        let lineBreak = "\r\n"
        var body = Data()

        for (name, value) in fields {
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append("\(value)\(lineBreak)".data(using: .utf8)!)
        }

        // Synology returns 101 Invalid parameter if the filename in Content-Disposition
        // contains non-ASCII characters (e.g. Czech diacritics) or characters that break
        // the header syntax. Sanitize aggressively: RFC 6266's basic `filename=""` is
        // ASCII-only, and the actual torrent task name comes from the .torrent file's
        // bencoded `name` key anyway, not from this header.
        let safeFilename = Self.asciiSafe(filename: filename)
        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(safeFilename)\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(fileData)
        body.append("\(lineBreak)--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }

    private static func asciiSafe(filename: String) -> String {
        let stripped = filename.applyingTransform(.stripDiacritics, reverse: false) ?? filename
        let ascii = String(stripped.unicodeScalars.compactMap { $0.isASCII ? Character($0) : nil })
        // Strip characters that would break the quoted filename in the header.
        let cleaned = ascii.filter { $0 != "\"" && $0 != "\\" && $0 != "\r" && $0 != "\n" }
        return cleaned.isEmpty ? "file.torrent" : cleaned
    }

    private func postForm<T: Decodable>(url: URL, params: [String: String]) async throws -> APIResponse<T> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var authenticatedParams = params
        // Login starts a new identity; never attach a previous session token.
        if params["method"] != "login", let token = authSession?.synoToken {
            authenticatedParams["SynoToken"] = token
        }
        request.httpBody = encodeForm(authenticatedParams).data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw APIError.http(http.statusCode)
            }
            do {
                return try JSONDecoder().decode(APIResponse<T>.self, from: data)
            } catch {
                throw APIError.decoding(error)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw mapTransportError(error, requestURL: request.url)
        }
    }

    private func encodeForm(_ params: [String: String]) -> String {
        params.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: Self.formAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: Self.formAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    /// RFC 3986 unreserved set (`A-Z a-z 0-9 - . _ ~`). Anything else — including the
    /// form delimiters `&` `=` `+`, but also `,` `/` `:` and the `?` plus `&` chains
    /// inside magnet URIs — gets percent-encoded. The previous `.urlQueryAllowed`
    /// permitted `&` in values, so a magnet link's trailing `&dn=…&tr=…` was passed
    /// through unencoded and the server saw each `&` as a new form parameter
    /// boundary, producing Synology error 101 "Invalid parameter" on createTask.
    private static let formAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
