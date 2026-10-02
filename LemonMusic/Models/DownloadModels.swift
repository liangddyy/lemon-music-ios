import Foundation

nonisolated enum NASQuality: String, CaseIterable, Codable, Sendable {
    case mp3 = "320k"
    case flac
    var title: String { self == .mp3 ? "MP3 · 320k" : "FLAC · 无损" }
}

nonisolated struct NASDownloadTask: Codable, Sendable, Identifiable {
    let id: String
    let title: String
    let status: String
    let progress: Double
    let error: String?

    init?(json: JSONValue) {
        guard let object = json.object, let id = object.firstString("id") else { return nil }
        self.id = id
        title = object.firstString("name") ?? "未知歌曲"
        status = object.firstString("status") ?? "waiting"
        progress = min(1, max(0, (object.firstDouble("progress") ?? 0) / 100))
        error = object.firstString("error")
    }

    var statusTitle: String {
        switch status {
        case "completed": "已完成"
        case "downloading": "下载中"
        case "error": "失败"
        case "paused": "已暂停"
        case "await_exist": "待处理同名文件 · NAS 网页端"
        case "await_source": "待确认换源 · NAS 网页端"
        case "await_confirm": "待确认音质 · NAS 网页端"
        default: "已提交"
        }
    }
}

nonisolated struct NASSubmission: Sendable {
    let ids: [String]
    let skipped: Int
}

nonisolated struct NASBatch: Codable, Sendable {
    let collectionKey: String
    let title: String
    let quality: NASQuality
    var tracks: [MusicTrack]
    var cursor = 0
    var skipped = 0
    var ids: [String] = []
    var tasks: [NASDownloadTask] = []
    var error: String?
    var submissionComplete: Bool { cursor >= tracks.count }
}

nonisolated extension MusicTrack {
    func downloadPayload(quality: NASQuality, batchID: String) -> JSONValue {
        var body = snapshotJSON.object ?? [:]
        body["songId"] = locator.songID.map(JSONValue.string) ?? .string("")
        body["quality"] = .string(quality.rawValue)
        body["preferredQuality"] = .string(quality.rawValue)
        body["qualityPolicy"] = .string("none")
        body["autoCascade"] = .bool(false)
        body["deferExistAsk"] = .bool(true)
        body["batchId"] = .string(batchID)
        return .object(body)
    }
}
