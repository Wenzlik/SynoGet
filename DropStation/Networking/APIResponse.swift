import Foundation

struct APIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: APIErrorPayload?

    struct APIErrorPayload: Decodable {
        let code: Int
    }
}

struct LoginData: Decodable {
    let sid: String
    let synotoken: String?
    /// Device id Synology returns when `enable_device_token=yes` is passed on a
    /// 2FA login. We don't request it (the flag suppresses Secure SignIn push)
    /// but keep the field around so the decoder still accepts responses that
    /// happen to include it.
    let did: String?
}

struct TaskListData: Decodable {
    // `total` and `offset` are returned by the list endpoint but not by getinfo
    // (which only returns `tasks`). Optional so both shapes decode cleanly.
    let total: Int?
    let offset: Int?
    let tasks: [DownloadTask]
}

struct EmptyData: Decodable {}

/// Payload of `SYNO.API.Info.query` — DSM returns a top-level JSON
/// object where each key is an API name (`SYNO.DownloadStation.Task`)
/// and the value describes the endpoint (CGI path, min/max version).
/// Decoded into a `[String: APIInfoEntry]` for ergonomics.
struct APIInfoEntry: Decodable {
    let path: String
    let minVersion: Int
    let maxVersion: Int

    enum CodingKeys: String, CodingKey {
        case path
        case minVersion = "minVersion"
        case maxVersion = "maxVersion"
    }
}

struct APIInfoData: Decodable {
    let entries: [String: APIInfoEntry]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.entries = try container.decode([String: APIInfoEntry].self)
    }
}

struct FileStationShareList: Decodable {
    let shares: [FileNode]
}

struct FileStationFileList: Decodable {
    let files: [FileNode]
}

/// Decode shape for `SYNO.FileStation.List` `list_share` when
/// requested with `additional=["volume_status"]`. Kept separate
/// from `FileStationShareList` (which feeds the destination
/// picker via the lean `FileNode`) so `FileNode` stays focused
/// on name/path/isdir and the storage probe owns its own shape.
struct ShareVolumeList: Decodable {
    let shares: [ShareVolume]
}

struct ShareVolume: Decodable {
    let additional: ShareAdditional?

    struct ShareAdditional: Decodable {
        let volumeStatus: VolumeStatus?

        enum CodingKeys: String, CodingKey {
            case volumeStatus = "volume_status"
        }
    }

    /// Per-volume capacity. DSM is inconsistent about returning
    /// these as JSON numbers vs. quoted strings (and very large
    /// volumes overflow Int32), hence `FlexibleInt64`.
    struct VolumeStatus: Decodable {
        let freespace: FlexibleInt64
        let totalspace: FlexibleInt64
    }
}

extension ShareVolumeList {
    /// Headline free-disk number for the hero card: the largest
    /// per-share free space. Multiple shares can sit on one
    /// volume, so summing would double-count; the max is a sound
    /// proxy for "the volume you'd download to" (single-volume
    /// NAS is the common case, and where there are several the
    /// emptiest is the most useful glance). `nil` when no share
    /// reported a volume_status (older DSM / restricted account).
    var headlineFreeBytes: Int64? {
        shares
            .compactMap { $0.additional?.volumeStatus?.freespace.value }
            .max()
    }
}
