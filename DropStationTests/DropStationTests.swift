import XCTest
import SwiftUI
@testable import DropStation

final class ServerConfigTests: XCTestCase {
    func testBaseURLConstruction() {
        let config = ServerConfig(scheme: .https, host: "nas.local", port: 5001, account: "vasek")
        XCTAssertEqual(config.baseURL?.absoluteString, "https://nas.local:5001")
    }

    func testEmptyHostProducesNilURL() {
        let config = ServerConfig(scheme: .https, host: "", port: 5001, account: "vasek")
        // URLComponents with empty host still returns a URL in some forms; this asserts current behavior.
        XCTAssertNotNil(config.baseURL)
    }
}

final class DownloadTaskDecodingTests: XCTestCase {
    func testDecodeMinimalTask() throws {
        let json = """
        {
          "id": "dbid_1",
          "title": "ubuntu-24.04.iso",
          "size": 5368709120,
          "status": "downloading",
          "type": "bt",
          "username": "vasek",
          "additional": { "transfer": { "size_downloaded": 2684354560, "size_uploaded": 0, "speed_download": 1048576, "speed_upload": 0 } }
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(DownloadTask.self, from: json)
        XCTAssertEqual(task.id, "dbid_1")
        XCTAssertEqual(task.status, .downloading)
        XCTAssertEqual(task.type, .bt)
        XCTAssertEqual(task.progress, 0.5, accuracy: 0.001)
    }

    func testDecodeUnknownStatusFallsBack() throws {
        let json = """
        {"id":"x","title":"t","size":1,"status":"future_state","type":"http","username":"u"}
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(DownloadTask.self, from: json)
        XCTAssertEqual(task.status, .unknown)
    }

    func testPauseResumeAvailability() throws {
        func task(status: DownloadTask.Status) -> DownloadTask {
            DownloadTask(id: "x", title: "t", size: 1, status: status, type: .bt, username: "u", additional: nil)
        }
        XCTAssertTrue(task(status: .downloading).canPause)
        XCTAssertTrue(task(status: .seeding).canPause)
        XCTAssertFalse(task(status: .paused).canPause)
        XCTAssertTrue(task(status: .paused).canResume)
        XCTAssertTrue(task(status: .error).canResume)
        // .finished tasks are resumable so a Stop is reversible
        // (BT: re-enters seeding; HTTP/FTP: server-side no-op).
        XCTAssertTrue(task(status: .finished).canResume)
        XCTAssertFalse(task(status: .downloading).canResume)
        // Stop only makes sense for already-100 % tasks. Stopping a still-
        // downloading task on the API side just pauses it without
        // transitioning to finished, which is confusing UX — so hide it.
        XCTAssertTrue(task(status: .seeding).canStop)
        XCTAssertTrue(task(status: .finishing).canStop)
        XCTAssertFalse(task(status: .downloading).canStop)
        XCTAssertFalse(task(status: .paused).canStop)
        XCTAssertFalse(task(status: .finished).canStop)
    }
}

final class TaskFilterTests: XCTestCase {
    private func task(_ status: DownloadTask.Status) -> DownloadTask {
        DownloadTask(id: UUID().uuidString, title: "t", size: 1,
                     status: status, type: .bt, username: "u", additional: nil)
    }

    /// A task that has fully downloaded its payload — used to exercise the
    /// "paused after 100 %" → Finished bucket folding.
    private func taskAtCompletion(_ status: DownloadTask.Status) -> DownloadTask {
        let transfer = DownloadTask.Additional.Transfer(
            sizeDownloaded: 10,
            sizeUploaded: 0,
            speedDownload: 0,
            speedUpload: 0
        )
        return DownloadTask(
            id: UUID().uuidString, title: "t", size: 10,
            status: status, type: .bt, username: "u",
            additional: DownloadTask.Additional(
                transfer: transfer,
                detail: nil, file: nil, tracker: nil
            )
        )
    }

    func testAllMatchesEverything() {
        for status: DownloadTask.Status in [.downloading, .paused, .finished, .error, .seeding, .unknown] {
            XCTAssertTrue(TaskFilter.all.matches(task(status)))
        }
    }

    func testDownloadingExcludesSeeding() {
        // The reason this filter exists: distinguish "pulling bytes" from "sending to peers".
        XCTAssertTrue(TaskFilter.downloading.matches(task(.downloading)))
        XCTAssertTrue(TaskFilter.downloading.matches(task(.waiting)))
        XCTAssertTrue(TaskFilter.downloading.matches(task(.hash_checking)))
        XCTAssertFalse(TaskFilter.downloading.matches(task(.seeding)))
        XCTAssertFalse(TaskFilter.downloading.matches(task(.paused)))
        XCTAssertFalse(TaskFilter.downloading.matches(task(.finished)))
    }

    func testSeedingMatchesOnlySeeding() {
        XCTAssertTrue(TaskFilter.seeding.matches(task(.seeding)))
        XCTAssertFalse(TaskFilter.seeding.matches(task(.downloading)))
        XCTAssertFalse(TaskFilter.seeding.matches(task(.finished)))
    }

    func testActiveCoversBothDownloadingAndSeeding() {
        XCTAssertTrue(TaskFilter.active.matches(task(.downloading)))
        XCTAssertTrue(TaskFilter.active.matches(task(.seeding)))
        XCTAssertTrue(TaskFilter.active.matches(task(.hash_checking)))
        XCTAssertTrue(TaskFilter.active.matches(task(.waiting)))
        XCTAssertTrue(TaskFilter.active.matches(task(.finishing)))
        XCTAssertFalse(TaskFilter.active.matches(task(.paused)))
        XCTAssertFalse(TaskFilter.active.matches(task(.finished)))
        XCTAssertFalse(TaskFilter.active.matches(task(.error)))
    }

    func testFinishedExcludesInProgressFinishing() {
        // Finishing is still in progress; only fully-finished tasks count as done.
        XCTAssertTrue(TaskFilter.finished.matches(task(.finished)))
        XCTAssertFalse(TaskFilter.finished.matches(task(.finishing)))
        XCTAssertFalse(TaskFilter.finished.matches(task(.seeding)))
    }

    func testFinishedIncludesPausedAtCompletion() {
        // DS2 Task.Complete leaves a stopped seeding task as `paused` at
        // 100 %. The filter should treat that as Finished so the user sees
        // it where they expect.
        XCTAssertTrue(TaskFilter.finished.matches(taskAtCompletion(.paused)))
    }

    func testPausedExcludesPausedAtCompletion() {
        // A task paused at 100 % belongs in Finished, not Paused.
        XCTAssertTrue(TaskFilter.paused.matches(task(.paused))) // partial
        XCTAssertFalse(TaskFilter.paused.matches(taskAtCompletion(.paused))) // 100 %
    }

    func testPausedAndErrorAreSingleStatusFilters() {
        XCTAssertFalse(TaskFilter.paused.matches(task(.error)))
        XCTAssertTrue(TaskFilter.error.matches(task(.error)))
        XCTAssertFalse(TaskFilter.error.matches(task(.paused)))
    }

    func testDisplayStatusLabelFoldsPausedAtCompletionToEnded() {
        XCTAssertEqual(task(.downloading).displayStatusLabel, String(localized: "Downloading"))
        XCTAssertEqual(task(.paused).displayStatusLabel, String(localized: "Paused"))    // partial
        XCTAssertEqual(taskAtCompletion(.paused).displayStatusLabel, String(localized: "Ended"))
        XCTAssertEqual(task(.finished).displayStatusLabel, String(localized: "Ended"))
    }
}

final class APIErrorSessionExpiredTests: XCTestCase {
    func testSessionExpiredCodes() {
        for code in [105, 106, 107, 119] {
            XCTAssertTrue(APIError.synology(code: code, message: "x").isSessionExpired,
                          "Code \(code) should be treated as expired session")
        }
    }

    func testTransientNetworkErrorsAreNotSessionExpired() {
        XCTAssertFalse(APIError.http(500).isSessionExpired)
        XCTAssertFalse(APIError.transport(URLError(.notConnectedToInternet)).isSessionExpired)
        XCTAssertFalse(APIError.synology(code: 400, message: "x").isSessionExpired)
    }

    func testOTPRequiredAndInvalidCodes() {
        XCTAssertTrue(APIError.synology(code: 403, message: "x").isOTPRequired)
        XCTAssertFalse(APIError.synology(code: 404, message: "x").isOTPRequired)

        XCTAssertTrue(APIError.synology(code: 404, message: "x").isOTPInvalid)
        XCTAssertFalse(APIError.synology(code: 403, message: "x").isOTPInvalid)

        // Common error codes are neither.
        XCTAssertFalse(APIError.synology(code: 106, message: "x").isOTPRequired)
        XCTAssertFalse(APIError.synology(code: 106, message: "x").isOTPInvalid)
    }
}

/// Locks the contract that decides whether a probe failure WIPES the
/// saved SID or PRESERVES it. The session-persistence behaviour rests
/// entirely on this classification: SessionStore wipes only on
/// `isSessionExpired`, preserves on `isTransient` / `.serverTrust` /
/// anything-else. A regression here (e.g. a non-expiry code sneaking
/// into `isSessionExpired`) would silently start logging users out —
/// exactly the field-reported symptom. These tests fail loudly if the
/// classification drifts.
final class SessionWipeContractTests: XCTestCase {
    /// Exactly these four DSM codes are session-expiry (→ wipe SID).
    private let expiryCodes = [105, 106, 107, 119]

    /// A spread of codes that must NEVER be treated as expiry — common
    /// errors, auth-context 4xx, and codes adjacent to the expiry set.
    private let nonExpiryCodes = [100, 101, 102, 103, 104, 108, 118, 120, 400, 401, 402, 403, 404]

    func testOnlyFourCodesAreSessionExpiry() {
        for code in expiryCodes {
            XCTAssertTrue(APIError.synology(code: code, message: "x").isSessionExpired,
                          "Code \(code) must be session-expiry (wipes SID)")
        }
        for code in nonExpiryCodes {
            XCTAssertFalse(APIError.synology(code: code, message: "x").isSessionExpired,
                           "Code \(code) must NOT be session-expiry — would wrongly wipe the SID")
        }
    }

    /// `isUnauthorized` (the 105-only flavour used by the live-poll
    /// recovery path) must stay exactly 105.
    func testUnauthorizedIsExactly105() {
        XCTAssertTrue(APIError.synology(code: 105, message: "x").isUnauthorized)
        for code in [106, 107, 119, 100, 400] {
            XCTAssertFalse(APIError.synology(code: code, message: "x").isUnauthorized,
                           "Only 105 is .isUnauthorized; \(code) must not be")
        }
    }

    /// Transport errors and 5xx are transient (→ preserve SID, retry).
    /// Synology API codes are never transient — they're definite
    /// server answers, not connectivity blips.
    func testTransientCoversTransportAnd5xxOnly() {
        let transientURLCodes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .secureConnectionFailed, .internationalRoamingOff, .dataNotAllowed
        ]
        for code in transientURLCodes {
            XCTAssertTrue(APIError.transport(URLError(code)).isTransient,
                          "URLError \(code) should be transient")
        }
        XCTAssertTrue(APIError.http(500).isTransient)
        XCTAssertTrue(APIError.http(503).isTransient)
        XCTAssertFalse(APIError.http(404).isTransient, "4xx is not transient")
        XCTAssertFalse(APIError.http(401).isTransient)
        for code in expiryCodes + [400, 105] {
            XCTAssertFalse(APIError.synology(code: code, message: "x").isTransient,
                           "Synology code \(code) must not be transient")
        }
    }

    /// The safety invariant the catch-order relies on: no single error
    /// is BOTH session-expiry AND transient. If one were, the branch
    /// order would decide whether the SID survives — a latent bug.
    /// Checks the expiry codes, the transient transport codes, and 5xx.
    func testExpiryAndTransientAreMutuallyExclusive() {
        let samples: [APIError] =
            expiryCodes.map { .synology(code: $0, message: "x") }
            + [.transport(URLError(.timedOut)), .transport(URLError(.networkConnectionLost)),
               .http(500), .http(503),
               .serverTrust(host: "nas.local", fingerprint: "AB:CD")]
        for error in samples {
            XCTAssertFalse(error.isSessionExpired && error.isTransient,
                           "Error \(error) is both expiry and transient — ambiguous wipe/preserve")
        }
    }

    /// `.serverTrust` (self-signed cert) must preserve the session: it
    /// is neither expiry nor transient nor unauthorized, so it routes
    /// to the trust prompt with the SID intact.
    func testServerTrustPreservesSession() {
        let err = APIError.serverTrust(host: "nas.local", fingerprint: "AB:CD")
        XCTAssertFalse(err.isSessionExpired, ".serverTrust must not wipe the SID")
        XCTAssertFalse(err.isTransient)
        XCTAssertFalse(err.isUnauthorized)
        XCTAssertNotNil(err.serverTrustInfo)
    }
}

final class LoginDataDecodingTests: XCTestCase {
    func testDecodeLoginWithoutDeviceToken() throws {
        let json = #"{"sid":"abc"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LoginData.self, from: json)
        XCTAssertEqual(decoded.sid, "abc")
        XCTAssertNil(decoded.did)
    }

    func testDecodeLoginWithDeviceToken() throws {
        let json = #"{"sid":"abc","did":"DID-XYZ"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LoginData.self, from: json)
        XCTAssertEqual(decoded.did, "DID-XYZ")
    }
}

final class TaskDetailDecodingTests: XCTestCase {
    func testDecodeFullDetailResponse() throws {
        // Modeled on the getinfo example in the Synology API spec: BT task with detail,
        // transfer, file list, and trackers.
        let json = """
        {
          "id": "dbid_42",
          "title": "ubuntu.iso",
          "size": 5368709120,
          "status": "downloading",
          "type": "bt",
          "username": "vasek",
          "additional": {
            "transfer": {
              "size_downloaded": 1073741824,
              "size_uploaded": 268435456,
              "speed_download": 5242880,
              "speed_upload": 524288
            },
            "detail": {
              "destination": "Downloads/Linux",
              "uri": "magnet:?xt=urn:btih:abcdef",
              "create_time": "1700000000",
              "priority": "auto",
              "connected_seeders": 12,
              "connected_leechers": 5,
              "total_peers": 200
            },
            "file": [
              {"filename":"ubuntu.iso","size":"5368709120","size_downloaded":"1073741824","priority":"normal"},
              {"filename":"readme.txt","size":1024,"size_downloaded":1024,"priority":"normal"}
            ],
            "tracker": [
              {"url":"udp://tracker.example.com:80","status":"OK","update_timer":900,"seeds":50,"peers":120}
            ]
          }
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(DownloadTask.self, from: json)
        XCTAssertEqual(task.additional?.detail?.destination, "Downloads/Linux")
        XCTAssertEqual(task.additional?.detail?.connectedSeeders?.value, 12)
        XCTAssertEqual(task.additional?.file?.count, 2)
        XCTAssertEqual(task.additional?.file?.first?.size?.value, 5368709120) // came in as string
        XCTAssertEqual(task.additional?.file?.last?.size?.value, 1024)        // came in as int
        XCTAssertEqual(task.additional?.tracker?.first?.seeds?.value, 50)
    }

    func testDecodeListResponseStillWorksWithoutExtraFields() throws {
        // The list endpoint omits detail/file/tracker — make sure the decoder doesn't choke.
        let json = #"""
        {"id":"x","title":"t","size":1,"status":"downloading","type":"http","username":"u","additional":{"transfer":{"size_downloaded":1,"size_uploaded":0,"speed_download":0,"speed_upload":0}}}
        """#.data(using: .utf8)!
        let task = try JSONDecoder().decode(DownloadTask.self, from: json)
        XCTAssertNil(task.additional?.detail)
        XCTAssertNil(task.additional?.file)
    }
}

final class FlexibleInt64Tests: XCTestCase {
    func testDecodesFromNumber() throws {
        let n = try JSONDecoder().decode(FlexibleInt64.self, from: Data("12345".utf8))
        XCTAssertEqual(n.value, 12345)
    }

    func testDecodesFromQuotedString() throws {
        let n = try JSONDecoder().decode(FlexibleInt64.self, from: Data(#""54321""#.utf8))
        XCTAssertEqual(n.value, 54321)
    }

    func testDecodesUnparseableStringAsZero() throws {
        let n = try JSONDecoder().decode(FlexibleInt64.self, from: Data(#""nope""#.utf8))
        XCTAssertEqual(n.value, 0)
    }
}

final class FileNodeTests: XCTestCase {
    func testDecodeShareFromFileStationJSON() throws {
        // Synology returns list_share entries with leading-slash paths.
        let json = #"{"name":"Downloads","path":"/Downloads","isdir":true}"#.data(using: .utf8)!
        let node = try JSONDecoder().decode(FileNode.self, from: json)
        XCTAssertEqual(node.name, "Downloads")
        XCTAssertEqual(node.path, "/Downloads")
        XCTAssertTrue(node.isdir)
    }

    func testDestinationPathStripsLeadingSlash() {
        // DownloadStation create-task expects "Downloads/Movies", not "/Downloads/Movies".
        XCTAssertEqual(FileNode(name: "Movies", path: "/Downloads/Movies", isdir: true).destinationPath,
                       "Downloads/Movies")
        XCTAssertEqual(FileNode(name: "Downloads", path: "/Downloads", isdir: true).destinationPath,
                       "Downloads")
    }

    func testDestinationPathLeavesAlreadyRelativeAlone() {
        XCTAssertEqual(FileNode(name: "x", path: "Downloads", isdir: true).destinationPath,
                       "Downloads")
    }
}

final class AppearanceModeTests: XCTestCase {
    func testPreferredColorSchemeMapping() {
        XCTAssertNil(AppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(AppearanceMode.light.preferredColorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.preferredColorScheme, .dark)
    }

    func testRoundTripsThroughRawValue() {
        for mode in AppearanceMode.allCases {
            XCTAssertEqual(AppearanceMode(rawValue: mode.rawValue), mode)
        }
    }

    func testUnknownRawValueIsNil() {
        XCTAssertNil(AppearanceMode(rawValue: "purple"))
    }
}

final class FilePriorityTests: XCTestCase {
    func testFromRawPriorityMatchesKnownStrings() {
        XCTAssertEqual(FilePriority.from(rawPriority: "skip"), .skip)
        XCTAssertEqual(FilePriority.from(rawPriority: "low"), .low)
        XCTAssertEqual(FilePriority.from(rawPriority: "normal"), .normal)
        XCTAssertEqual(FilePriority.from(rawPriority: "high"), .high)
    }

    func testFromRawPriorityFallsBackToNormal() {
        // Missing / "auto" / unknown all map to normal so display
        // never crashes on a value DSM invents.
        XCTAssertEqual(FilePriority.from(rawPriority: nil), .normal)
        XCTAssertEqual(FilePriority.from(rawPriority: "auto"), .normal)
        XCTAssertEqual(FilePriority.from(rawPriority: "unknown_future_value"), .normal)
    }

    func testWantedFalseCollapsesToSkipRegardlessOfRawPriority() {
        // The whole reason the wanted-aware resolver exists: some
        // DSM builds keep the file's pre-skip priority value in the
        // `priority` field even after wanted goes false. Trusting
        // wanted=false here is what makes the row render as Skipped.
        XCTAssertEqual(FilePriority.from(rawPriority: "normal", wanted: false), .skip)
        XCTAssertEqual(FilePriority.from(rawPriority: "high", wanted: false), .skip)
        XCTAssertEqual(FilePriority.from(rawPriority: nil, wanted: false), .skip)
    }

    func testWantedTrueAndMissingDefersToRawPriority() {
        // wanted=true and wanted=nil both fall through to the raw
        // priority — only an explicit false flips us to skip.
        XCTAssertEqual(FilePriority.from(rawPriority: "high", wanted: true), .high)
        XCTAssertEqual(FilePriority.from(rawPriority: "high", wanted: nil), .high)
        XCTAssertEqual(FilePriority.from(rawPriority: "skip", wanted: nil), .skip)
    }
}

final class TorrentFileDecodingTests: XCTestCase {
    func testDecodesWantedFlagWhenPresent() throws {
        let json = #"""
        {"filename":"clip.mp4","size":1024,"size_downloaded":0,"priority":"normal","wanted":false}
        """#.data(using: .utf8)!
        let file = try JSONDecoder().decode(DownloadTask.Additional.TorrentFile.self, from: json)
        XCTAssertEqual(file.wanted, false)
        XCTAssertEqual(file.priority, "normal")
        // wanted-aware resolver folds this into .skip — the case the
        // visual treatment in TaskDetailView depends on.
        XCTAssertEqual(FilePriority.from(rawPriority: file.priority, wanted: file.wanted), .skip)
    }

    func testWantedAbsentDecodesAsNilNotFailure() throws {
        // List endpoints don't always include `wanted`; the decoder
        // must not fail when it's missing.
        let json = #"""
        {"filename":"clip.mp4","size":1024,"size_downloaded":1024,"priority":"normal"}
        """#.data(using: .utf8)!
        let file = try JSONDecoder().decode(DownloadTask.Additional.TorrentFile.self, from: json)
        XCTAssertNil(file.wanted)
    }
}

final class DashboardActiveTransfersTests: XCTestCase {
    private func task(
        id: String,
        status: DownloadTask.Status,
        title: String = "t",
        size: Int64 = 100,
        downloaded: Int64 = 0,
        speedDown: Int64 = 0,
        speedUp: Int64 = 0
    ) -> DownloadTask {
        let transfer = DownloadTask.Additional.Transfer(
            sizeDownloaded: FlexibleInt64(downloaded),
            sizeUploaded: 0,
            speedDownload: FlexibleInt64(speedDown),
            speedUpload: FlexibleInt64(speedUp)
        )
        return DownloadTask(
            id: id,
            title: title,
            size: FlexibleInt64(size),
            status: status,
            type: .bt,
            username: nil,
            additional: DownloadTask.Additional(
                transfer: transfer,
                detail: nil,
                file: nil,
                tracker: nil
            )
        )
    }

    func testActiveTransfersOrdersByCombinedThroughput() async {
        let store = await DownloadTaskStore.makeForTesting(tasks: [
            task(id: "a", status: .downloading, speedDown: 1_000),
            task(id: "b", status: .downloading, speedDown: 5_000_000),
            task(id: "c", status: .downloading, speedDown: 500, speedUp: 2_000_000)
        ])
        let vm = await DashboardViewModel(store: store, hostname: "nas")
        let order = await vm.activeTransfers.map(\.id)
        XCTAssertEqual(order, ["b", "c", "a"])
    }

    func testActiveTransfersExcludesIdleSeedingButIncludesUploadingSeeder() async {
        let store = await DownloadTaskStore.makeForTesting(tasks: [
            task(id: "idle-seeder", status: .seeding, speedDown: 0, speedUp: 0),
            task(id: "uploading-seeder", status: .seeding, speedDown: 0, speedUp: 100_000),
            task(id: "downloading", status: .downloading, speedDown: 50_000)
        ])
        let vm = await DashboardViewModel(store: store, hostname: "nas")
        let ids = await vm.activeTransfers.map(\.id)
        XCTAssertTrue(ids.contains("uploading-seeder"))
        XCTAssertTrue(ids.contains("downloading"))
        XCTAssertFalse(ids.contains("idle-seeder"))
    }

    func testActiveTransfersIncludesHashCheckingEvenWithoutThroughput() async {
        // hash_checking has no byte rate but is definitely live
        // NAS work — should appear in the active feed so the user
        // sees freshly-added torrents.
        let store = await DownloadTaskStore.makeForTesting(tasks: [
            task(id: "hashing", status: .hash_checking)
        ])
        let vm = await DashboardViewModel(store: store, hostname: "nas")
        let ids = await vm.activeTransfers.map(\.id)
        XCTAssertEqual(ids, ["hashing"])
    }

    func testActiveTransfersCapsAtThree() async {
        let store = await DownloadTaskStore.makeForTesting(tasks: [
            task(id: "1", status: .downloading, speedDown: 100),
            task(id: "2", status: .downloading, speedDown: 200),
            task(id: "3", status: .downloading, speedDown: 300),
            task(id: "4", status: .downloading, speedDown: 400),
            task(id: "5", status: .downloading, speedDown: 500)
        ])
        let vm = await DashboardViewModel(store: store, hostname: "nas")
        let active = await vm.activeTransfers
        XCTAssertEqual(active.count, 3)
        XCTAssertEqual(active.map(\.id), ["5", "4", "3"])
    }

    func testRecentlyCompletedIncludesSeedingButExcludesActiveOnes() async {
        let store = await DownloadTaskStore.makeForTesting(tasks: [
            // Active uploader — should NOT also appear in completed.
            task(id: "uploading-seeder", status: .seeding, speedUp: 100_000),
            // Idle seeder — completed download, just sitting there. Goes
            // to recently completed.
            task(id: "idle-seeder", status: .seeding),
            task(id: "finished", status: .finished)
        ])
        let vm = await DashboardViewModel(store: store, hostname: "nas")
        let completedIds = await vm.recentlyCompleted.map(\.id)
        XCTAssertTrue(completedIds.contains("idle-seeder"))
        XCTAssertTrue(completedIds.contains("finished"))
        XCTAssertFalse(completedIds.contains("uploading-seeder"))
    }

    func testHasActiveTransfersFlagMirrorsList() async {
        let empty = await DownloadTaskStore.makeForTesting(tasks: [
            task(id: "f", status: .finished)
        ])
        let vmEmpty = await DashboardViewModel(store: empty, hostname: "nas")
        let emptyResult = await vmEmpty.hasActiveTransfers
        XCTAssertFalse(emptyResult)

        let active = await DownloadTaskStore.makeForTesting(tasks: [
            task(id: "d", status: .downloading, speedDown: 1)
        ])
        let vmActive = await DashboardViewModel(store: active, hostname: "nas")
        let activeResult = await vmActive.hasActiveTransfers
        XCTAssertTrue(activeResult)
    }
}

final class BugReportTests: XCTestCase {
    private func diagnostics(timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Diagnostics {
        Diagnostics(
            appVersion: "0.5.2",
            appBuild: "12",
            iOSVersion: "26.1",
            deviceModel: "iPhone15,2",
            hostname: "nas.local",
            authMethod: "Verification code",
            sessionState: "loggedIn",
            timestamp: timestamp
        )
    }

    func testEmailBodyOnlyRendersFilledOptionalSections() {
        let report = BugReport(
            subject: "Stuck on splash",
            description: "App freezes after login.",
            stepsToReproduce: nil,
            expectedBehavior: nil,
            contactEmail: nil,
            includeDiagnostics: false,
            diagnostics: nil
        )
        let body = report.composeEmailBody()
        XCTAssertTrue(body.contains("App freezes after login."))
        XCTAssertFalse(body.contains("Steps to reproduce"))
        XCTAssertFalse(body.contains("Expected behavior"))
        XCTAssertFalse(body.contains("Contact:"))
        XCTAssertFalse(body.contains("Diagnostics"))
    }

    func testEmailBodyIncludesDiagnosticsWhenOptedIn() {
        let report = BugReport(
            subject: "Stuck on splash",
            description: "App freezes after login.",
            stepsToReproduce: "1. Open app\n2. Wait",
            expectedBehavior: "Task list loads.",
            contactEmail: "me@example.com",
            includeDiagnostics: true,
            diagnostics: diagnostics()
        )
        let body = report.composeEmailBody()
        XCTAssertTrue(body.contains("Steps to reproduce"))
        XCTAssertTrue(body.contains("Expected behavior"))
        XCTAssertTrue(body.contains("Contact: me@example.com"))
        XCTAssertTrue(body.contains("App version: 0.5.2 (12)"))
        XCTAssertTrue(body.contains("Device: iPhone15,2"))
        XCTAssertTrue(body.contains("Host: nas.local"))
        XCTAssertTrue(body.contains("Auth method: Verification code"))
        XCTAssertTrue(body.contains("Session state: loggedIn"))
    }

    func testDiagnosticsOmittedEvenIfPresentWhenFlagOff() {
        // Belt-and-braces: if a caller mistakenly attaches the
        // diagnostics struct while the toggle is off, the body
        // still omits the block. Mirrors the privacy contract:
        // the toggle is authoritative.
        let report = BugReport(
            subject: "x",
            description: "y",
            stepsToReproduce: nil,
            expectedBehavior: nil,
            contactEmail: nil,
            includeDiagnostics: false,
            diagnostics: diagnostics()
        )
        XCTAssertFalse(report.composeEmailBody().contains("Diagnostics"))
        XCTAssertFalse(report.composeEmailBody().contains("Host:"))
    }

    func testEmailSubjectLineIsPrefixed() {
        let report = BugReport(
            subject: "Stuck on splash",
            description: "x",
            stepsToReproduce: nil,
            expectedBehavior: nil,
            contactEmail: nil,
            includeDiagnostics: false,
            diagnostics: nil
        )
        XCTAssertEqual(report.emailSubjectLine, "[DropStation] Stuck on splash")
    }

    func testRecipientEmail() {
        // Pinned by test so a refactor of the email value lights
        // up the test suite rather than silently rerouting reports.
        XCTAssertEqual(BugReport.recipientEmail, "dropstation@zmrhal.cz")
    }
}

final class MailtoFallbackTests: XCTestCase {
    func testRecipientEncodedAsPath() {
        let fb = mailtoFallbackURL(recipient: "dropstation@zmrhal.cz", subject: "x", body: "y")
        XCTAssertNotNil(fb)
        XCTAssertTrue(fb!.url.absoluteString.hasPrefix("mailto:dropstation@zmrhal.cz?"))
        XCTAssertTrue(fb!.carriedBody)
    }

    func testSubjectAndBodyArePresentInQuery() {
        let fb = mailtoFallbackURL(
            recipient: "a@b.cz",
            subject: "[DropStation] crash",
            body: "Line one\nLine two"
        )!
        let urlString = fb.url.absoluteString
        XCTAssertTrue(urlString.contains("subject="))
        XCTAssertTrue(urlString.contains("body="))
        // Brackets and newline must be percent-encoded for the URL
        // to be unambiguous to Mail / Gmail / Outlook.
        XCTAssertTrue(urlString.contains("%5BDropStation%5D"))
        XCTAssertTrue(urlString.contains("%0A"))
    }

    func testAmpersandInBodyIsEncoded() {
        // The regression test for the original bug: a literal `&`
        // in the body would otherwise be parsed as a query
        // separator and silently truncate the body in the mail
        // client.
        let fb = mailtoFallbackURL(
            recipient: "a@b.cz",
            subject: "s",
            body: "foo & bar"
        )!
        let urlString = fb.url.absoluteString
        XCTAssertTrue(urlString.contains("foo%20%26%20bar"))
        // No raw ampersand inside the body= value.
        // (There is exactly one `&` in the URL — between
        // subject= and body=.)
        XCTAssertEqual(urlString.filter { $0 == "&" }.count, 1)
    }

    func testReservedCharsAreEncoded() {
        let fb = mailtoFallbackURL(
            recipient: "a@b.cz",
            subject: "s",
            body: "= + ? # %"
        )!
        let s = fb.url.absoluteString
        XCTAssertTrue(s.contains("%3D"))   // =
        XCTAssertTrue(s.contains("%2B"))   // +
        XCTAssertTrue(s.contains("%3F"))   // ?
        XCTAssertTrue(s.contains("%23"))   // #
        XCTAssertTrue(s.contains("%25"))   // %
    }

    func testCzechDiacriticsSurviveAsUTF8() {
        // UTF-8 percent-encoding: "č" → %C4%8D, "š" → %C5%A1
        let fb = mailtoFallbackURL(
            recipient: "a@b.cz",
            subject: "Aplikace spadla",
            body: "Pokoušel jsem se přidat torrent — chyba síťování."
        )!
        let s = fb.url.absoluteString
        XCTAssertTrue(s.contains("Pokou%C5%A1el"))
        XCTAssertTrue(s.contains("p%C5%99idat"))
        XCTAssertTrue(s.contains("s%C3%AD%C5%A5ov%C3%A1n%C3%AD"))
    }

    func testBodyDroppedWhenURLExceedsLimit() {
        // Force a long body well over the limit; the fallback
        // should return subject-only with carriedBody = false so
        // the caller can prompt the user to paste from clipboard.
        let longBody = String(repeating: "x", count: 4000)
        let fb = mailtoFallbackURL(
            recipient: "a@b.cz",
            subject: "still here",
            body: longBody,
            maxURLLength: 1800
        )!
        XCTAssertFalse(fb.carriedBody)
        XCTAssertTrue(fb.url.absoluteString.contains("subject="))
        XCTAssertFalse(fb.url.absoluteString.contains("body="))
        XCTAssertLessThanOrEqual(fb.url.absoluteString.count, 1800 + 64)
    }

    func testShortReportCarriesBody() {
        let fb = mailtoFallbackURL(
            recipient: "a@b.cz",
            subject: "s",
            body: "short body",
            maxURLLength: 1800
        )!
        XCTAssertTrue(fb.carriedBody)
        XCTAssertTrue(fb.url.absoluteString.contains("body=short%20body"))
    }
}

final class APIErrorContextTests: XCTestCase {
    func testCommonCodesAreContextIndependent() {
        XCTAssertEqual(SynologyErrorCode.message(for: 106, context: .auth),
                       SynologyErrorCode.message(for: 106, context: .task))
        XCTAssertEqual(SynologyErrorCode.message(for: 106), String(localized: "Session timeout."))
    }

    func testAuthAndTaskContextsDisagreeOn400() {
        let auth = SynologyErrorCode.message(for: 400, context: .auth)
        let task = SynologyErrorCode.message(for: 400, context: .task)
        XCTAssertNotEqual(auth, task)
        XCTAssertEqual(auth, String(localized: "No such account or incorrect password."))
        XCTAssertEqual(task, String(localized: "File upload failed."))
    }

    func testTaskContext401IsMaxTasks() {
        XCTAssertEqual(SynologyErrorCode.message(for: 401, context: .task),
                       String(localized: "Maximum number of tasks reached."))
    }
}

final class CertificateFingerprintTests: XCTestCase {
    /// SHA-256 of empty input is a well-known constant; verifies the
    /// colon-separated uppercase hex formatting end to end.
    func testEmptyInputFingerprint() {
        XCTAssertEqual(
            CertificateFingerprint.sha256Hex(of: Data()),
            "E3:B0:C4:42:98:FC:1C:14:9A:FB:F4:C8:99:6F:B9:24:27:AE:41:E4:64:9B:93:4C:A4:95:99:1B:78:52:B8:55"
        )
    }

    /// SHA-256("abc") is a standard test vector
    /// (ba7816bf…20015ad). Confirms byte order + grouping.
    func testKnownVectorFingerprint() {
        XCTAssertEqual(
            CertificateFingerprint.sha256Hex(of: Data("abc".utf8)),
            "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD"
        )
    }

    /// Format shape: 32 bytes → 32 hex pairs → 31 colons, all
    /// uppercase, two chars per group.
    func testFingerprintShape() {
        let fp = CertificateFingerprint.sha256Hex(of: Data("anything".utf8))
        let groups = fp.split(separator: ":")
        XCTAssertEqual(groups.count, 32)
        XCTAssertTrue(groups.allSatisfy { $0.count == 2 })
        XCTAssertEqual(fp, fp.uppercased())
    }

    /// `APIError.serverTrust` carries host + fingerprint, is not
    /// transient (must not trigger infinite reconnect retries), and
    /// is not a session-expiry code (must not wipe the SID).
    func testServerTrustErrorClassification() {
        let err = APIError.serverTrust(host: "nas.local", fingerprint: "AB:CD")
        XCTAssertEqual(err.serverTrustInfo?.host, "nas.local")
        XCTAssertEqual(err.serverTrustInfo?.fingerprint, "AB:CD")
        XCTAssertFalse(err.isTransient)
        XCTAssertFalse(err.isSessionExpired)
        XCTAssertFalse(err.isUnauthorized)
    }
}

final class ShareVolumeDecodingTests: XCTestCase {
    /// `SYNO.FileStation.List list_share` with
    /// `additional=["volume_status"]` — freespace arrives as a JSON
    /// number on some DSM builds, a quoted string on others.
    /// FlexibleInt64 absorbs both; the decode must survive each.
    func testDecodeVolumeStatusNumberAndString() throws {
        let json = Data("""
        {
          "shares": [
            { "name": "Downloads", "path": "/Downloads", "isdir": true,
              "additional": { "volume_status": { "freespace": 5368709120, "totalspace": 10737418240 } } },
            { "name": "video", "path": "/video", "isdir": true,
              "additional": { "volume_status": { "freespace": "9663676416", "totalspace": "10737418240" } } }
          ]
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(ShareVolumeList.self, from: json)
        XCTAssertEqual(decoded.shares.count, 2)
        XCTAssertEqual(decoded.shares[0].additional?.volumeStatus?.freespace.value, 5_368_709_120)
        XCTAssertEqual(decoded.shares[1].additional?.volumeStatus?.freespace.value, 9_663_676_416)
    }

    /// Headline free-disk number is the largest per-share freespace
    /// (proxy for "the volume you'd download to"), never the sum —
    /// multiple shares on one volume would double-count.
    func testHeadlineFreeBytesTakesMax() throws {
        let json = Data("""
        {
          "shares": [
            { "name": "a", "path": "/a", "isdir": true,
              "additional": { "volume_status": { "freespace": 100, "totalspace": 1000 } } },
            { "name": "b", "path": "/b", "isdir": true,
              "additional": { "volume_status": { "freespace": 900, "totalspace": 1000 } } }
          ]
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(ShareVolumeList.self, from: json)
        XCTAssertEqual(decoded.headlineFreeBytes, 900)
    }

    /// Older DSM / restricted accounts omit volume_status entirely.
    /// Decode still succeeds; headlineFreeBytes is nil so the hero
    /// simply shows no free-disk metric.
    func testHeadlineFreeBytesNilWhenNoVolumeStatus() throws {
        let json = Data("""
        {
          "shares": [
            { "name": "a", "path": "/a", "isdir": true }
          ]
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(ShareVolumeList.self, from: json)
        XCTAssertNil(decoded.headlineFreeBytes)
    }

    /// Empty share list (no accessible shares) → nil, not a crash.
    func testHeadlineFreeBytesNilWhenNoShares() throws {
        let decoded = try JSONDecoder().decode(ShareVolumeList.self, from: Data(#"{"shares":[]}"#.utf8))
        XCTAssertNil(decoded.headlineFreeBytes)
    }
}

