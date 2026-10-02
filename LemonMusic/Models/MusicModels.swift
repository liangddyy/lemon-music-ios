// Derived from Cassette, licensed under MPL-2.0.

import Foundation

nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

nonisolated extension JSONValue {
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }
    var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }
    var int: Int? { double.map(Int.init) }
    var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): ["true", "1", "yes"].contains(value.lowercased())
        default: nil
        }
    }

    subscript(_ key: String) -> JSONValue? { object?[key] }

    static func from(_ value: Any) -> JSONValue {
        switch value {
        case let value as [String: Any]: .object(value.mapValues(JSONValue.from))
        case let value as [Any]: .array(value.map(JSONValue.from))
        case let value as String: .string(value)
        case let value as NSNumber:
            CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        default: .null
        }
    }
}

nonisolated struct PlaybackLocator: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable { case local, online }

    let kind: Kind
    let trackID: String?
    let filePath: String?
    let source: String?
    let songID: String?
    let identifiers: [String: String]
}

nonisolated struct MusicTrack: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumID: String?
    let artistID: String?
    let duration: TimeInterval
    let artworkURL: String?
    let format: String?
    let genre: String?
    let modifiedAt: TimeInterval?
    let locator: PlaybackLocator
    let downloadMetadata: [String: JSONValue]?

    static func == (lhs: MusicTrack, rhs: MusicTrack) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init?(json: JSONValue, defaultSource: String? = nil) {
        guard let object = json.object else { return nil }
        let filePath = object.firstString("filePath", "localPath")
        let source = object.firstString("source") ?? (filePath == nil ? defaultSource : "local")
        let trackID = object.firstString("trackId")
        let songID = object.firstString("songId", "songmid", "hash", "copyrightId", "id")
        let rawID = trackID ?? songID ?? filePath
        guard let rawID, !rawID.isEmpty else { return nil }

        let kind: PlaybackLocator.Kind = filePath != nil || trackID != nil || source == "local" ? .local : .online
        let identity = kind == .local
            ? "local:\(trackID ?? rawID)"
            : "online:\(source ?? "unknown"):\(songID ?? rawID)"

        var identifiers: [String: String] = [:]
        for key in ["songId", "songmid", "hash", "copyrightId", "albumAudioId", "albumId", "albumMid", "albummid", "musicId", "rid", "dcTargetId", "strMediaMid"] {
            if let value = object[key]?.string, !value.isEmpty { identifiers[key] = value }
        }

        self.id = object.firstString("key") ?? identity
        self.title = object.firstString("title", "name", "songName") ?? "未知歌曲"
        self.artist = object.firstString("artist", "singer", "artistName") ?? "未知歌手"
        self.album = object.firstString("album", "albumName") ?? ""
        self.albumID = object.firstString("albumId", "albumID", "albumMid", "albummid")
        self.artistID = object.firstString("artistId", "artistID", "singerId")
        self.duration = object.firstDouble("duration", "interval", "durationSeconds")
            ?? Self.parseDuration(object.firstString("interval", "duration") ?? "")
        self.artworkURL = object.firstString("picUrl", "img", "cover", "coverUrl", "artworkURL")
        self.format = object.firstString("format", "suffix", "type")
        self.genre = object.firstString("genre")
        self.modifiedAt = object.firstDouble("mtime", "modifiedAt", "savedAt")
        self.downloadMetadata = object.filter {
            ["types", "qualitys", "albumArtist", "year", "publishTime", "interval"].contains($0.key)
        }
        self.locator = PlaybackLocator(
            kind: kind,
            trackID: trackID,
            filePath: filePath,
            source: source,
            songID: songID,
            identifiers: identifiers
        )
    }

    var snapshotJSON: JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(id),
            "name": .string(title),
            "singer": .string(artist),
            "album": .string(album),
            "source": .string(locator.source ?? (locator.kind == .local ? "local" : "")),
            "duration": .number(duration),
        ]
        object.merge(downloadMetadata ?? [:]) { current, _ in current }
        if let filePath = locator.filePath { object["filePath"] = .string(filePath); object["localPath"] = .string(filePath) }
        if let trackID = locator.trackID { object["trackId"] = .string(trackID) }
        if let songID = locator.songID { object["songId"] = .string(songID) }
        if let artworkURL { object["picUrl"] = .string(artworkURL) }
        if let format { object["format"] = .string(format) }
        if let genre { object["genre"] = .string(genre) }
        if let albumID { object["albumId"] = .string(albumID) }
        if let artistID { object["artistId"] = .string(artistID) }
        for (key, value) in locator.identifiers { object[key] = .string(value) }
        return .object(object)
    }

    private static func parseDuration(_ value: String) -> TimeInterval {
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

nonisolated struct MusicAlbum: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: String?
    let year: String?
    let trackCount: Int?
    var providerID: String { String(id.split(separator: ":", maxSplits: 1).last ?? "") }
    var sourceID: String { String(id.split(separator: ":", maxSplits: 1).first ?? "local") }

    init?(json: JSONValue, defaultSource: String? = nil) {
        guard let object = json.object,
              let rawID = object.firstString("id", "albumId", "albumID", "albumMid", "albummid") else { return nil }
        let source = object.firstString("source") ?? defaultSource ?? "local"
        id = "\(source):\(rawID)"
        title = object.firstString("name", "title", "album") ?? "未知专辑"
        artist = object.firstString("artist", "singer", "artistName") ?? ""
        artworkURL = object.firstString("picUrl", "img", "cover", "coverUrl")
        year = object.firstString("year")
        trackCount = object.firstInt("songCount", "trackCount", "count")
    }
}

nonisolated struct MusicArtist: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let name: String
    let artworkURL: String?
    let albumCount: Int?

    init?(json: JSONValue) {
        guard let object = json.object else { return nil }
        let name = object.firstString("name", "artist", "singer") ?? "未知歌手"
        id = object.firstString("id", "artistId", "singerId") ?? name
        self.name = name
        artworkURL = object.firstString("picUrl", "img", "cover", "coverUrl")
        albumCount = object.firstInt("albumCount", "count")
    }
}

nonisolated struct MusicPlaylist: Identifiable, Codable, Sendable, Hashable {
    let id: String
    var name: String
    var tracks: [MusicTrack]
    var artworkURL: String?
    var createdAt: TimeInterval
    var preservedFields: [String: JSONValue] = [:]

    var isImported: Bool { preservedFields["playlistType"]?.string == "imported" || importURL != nil }
    var importSource: String? { preservedFields.firstString("importSource") }
    var importURL: String? { preservedFields.firstString("importUrl") }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    private enum CodingKeys: String, CodingKey {
        case id, name, tracks, artworkURL, createdAt, preservedFields
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        tracks = try values.decodeIfPresent([MusicTrack].self, forKey: .tracks) ?? []
        artworkURL = try values.decodeIfPresent(String.self, forKey: .artworkURL)
        createdAt = try values.decodeIfPresent(TimeInterval.self, forKey: .createdAt) ?? 0
        preservedFields = try values.decodeIfPresent([String: JSONValue].self, forKey: .preservedFields) ?? [:]
    }

    init(id: String = UUID().uuidString, name: String, tracks: [MusicTrack] = [], artworkURL: String? = nil, createdAt: TimeInterval = Date().timeIntervalSince1970) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.artworkURL = artworkURL
        self.createdAt = createdAt
    }

    init?(json: JSONValue, defaultSource: String? = nil) {
        guard let object = json.object else { return nil }
        let rawID = object.firstString("id", "playlistId", "topId") ?? UUID().uuidString
        id = defaultSource.map { "\($0):\(rawID)" } ?? rawID
        name = object.firstString("name", "title") ?? "未命名歌单"
        artworkURL = object.firstString("coverUrl", "picUrl", "img", "cover", "coverImgUrl")
        createdAt = object.firstDouble("createdAt") ?? Date().timeIntervalSince1970
        preservedFields = object
        if let snapshots = object["trackSnapshots"]?.object {
            let orderedKeys = object["trackKeys"]?.array?.compactMap(\.string) ?? snapshots.keys.sorted()
            tracks = orderedKeys.compactMap { key in
                snapshots[key].flatMap { MusicTrack(json: $0, defaultSource: defaultSource) }
            }
        } else {
            tracks = object.firstArray("tracks", "list", "songs").compactMap { MusicTrack(json: $0, defaultSource: defaultSource) }
        }
    }

    var json: JSONValue {
        let snapshots = Dictionary(tracks.map { ($0.id, $0.snapshotJSON) }, uniquingKeysWith: { first, _ in first })
        var object = preservedFields
        object.merge([
            "id": .string(id),
            "name": .string(name),
            "trackKeys": .array(tracks.map { .string($0.id) }),
            "trackSnapshots": .object(snapshots),
            "coverUrl": artworkURL.map(JSONValue.string) ?? .string(""),
            "createdAt": .number(createdAt),
            "playlistType": .string(isImported ? "imported" : "custom"),
        ]) { _, new in new }
        return .object(object)
    }

    var providerID: String { String(id.split(separator: ":", maxSplits: 1).last ?? "") }
}

nonisolated struct MusicSource: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let name: String
}

nonisolated struct SessionUser: Codable, Sendable, Equatable {
    let id: String
    let username: String
    let displayName: String
    let role: String
}

nonisolated struct LoginSession: Codable, Sendable {
    let token: String
    let user: SessionUser
}

nonisolated struct LibraryUserData: Codable, Sendable, Equatable {
    var playlists: [MusicPlaylist]
    var favorites: [MusicTrack]
    var recentPlays: [MusicTrack]
    var revision: Int

    static let empty = LibraryUserData(playlists: [], favorites: [], recentPlays: [], revision: 0)
}

nonisolated extension Dictionary where Key == String, Value == JSONValue {
    func firstString(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.string, !value.isEmpty { return value }
        }
        return nil
    }

    func firstDouble(_ keys: String...) -> Double? {
        for key in keys { if let value = self[key]?.double { return value } }
        return nil
    }

    func firstInt(_ keys: String...) -> Int? {
        for key in keys { if let value = self[key]?.int { return value } }
        return nil
    }

    func firstArray(_ keys: String...) -> [JSONValue] {
        for key in keys { if let value = self[key]?.array { return value } }
        return []
    }
}
