import Foundation

nonisolated struct OnlineCollection: Hashable, Sendable {
    enum Kind: String, Sendable { case toplist, album, playlist }
    let kind: Kind
    let source: String
    let id: String
    let title: String

    var cacheKey: String { "collection.\(kind.rawValue).\(source).\(id)" }
}

nonisolated struct TrackPage: Codable, Sendable {
    let tracks: [MusicTrack]
    let total: Int
}

nonisolated enum OnlineSearchKind: String, CaseIterable, Identifiable {
    case songs = "歌曲"
    case albums = "专辑"
    case playlists = "歌单"
    var id: Self { self }
}
