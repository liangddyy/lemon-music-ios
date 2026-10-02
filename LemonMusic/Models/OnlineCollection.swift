import Foundation

nonisolated struct OnlineCollection: Hashable, Sendable {
    enum Kind: String, Sendable { case toplist, album, playlist }
    let kind: Kind
    let source: String
    let id: String
    let title: String
    var artworkURL: String? = nil

    var cacheKey: String { "collection.\(kind.rawValue).\(source).\(id)" }
}

nonisolated struct LocalCollection: Hashable, Sendable {
    enum Kind: String, Sendable { case album, artist, genre }
    let kind: Kind
    let value: String
    var artist: String? = nil
    var artworkURL: String? = nil
    var artworkCacheKey: String? = nil
    var cacheKey: String { "local-collection.\(kind.rawValue).\(value).\(artist ?? "")" }
}

nonisolated enum CollectionSource: Hashable, Sendable {
    case playlist(MusicPlaylist)
    case online(OnlineCollection)
    case local(LocalCollection)

    var key: String {
        if let identity = favoriteIdentity {
            return "collection.playlist.\(identity.source).\(PlaylistIdentity.canonicalID(identity.id))"
        }
        switch self {
        case .playlist(let value): return "playlist.\(value.id)"
        case .online(let value): return value.cacheKey
        case .local(let value): return value.cacheKey
        }
    }

    var title: String {
        switch self {
        case .playlist(let value): value.name
        case .online(let value): value.title
        case .local(let value): value.value
        }
    }

    var artworkURL: String? {
        switch self {
        case .playlist(let value): value.artworkURL
        case .online(let value): value.artworkURL
        case .local(let value): value.artworkURL
        }
    }

    var artworkCacheKey: String {
        switch self {
        case .playlist(let value): "playlist:\(value.id)"
        case .online(let value):
            "\(value.kind == .album ? "album" : "playlist"):\(value.source):\(value.id)"
        case .local(let value): value.artworkCacheKey ?? "playlist:\(value.cacheKey)"
        }
    }

    var subtitle: String {
        switch self {
        case .playlist(let value): value.isImported ? "收藏歌单" : "我的歌单"
        case .online(let value):
            switch value.kind {
            case .playlist: "在线歌单"
            case .album: "在线专辑"
            case .toplist: "排行榜"
            }
        case .local: "NAS 音乐库"
        }
    }

    var favoriteIdentity: (source: String, id: String)? {
        switch self {
        case .online(let value) where value.kind == .playlist: (value.source, value.id)
        case .playlist(let value) where value.isImported:
            if let source = value.importSource, let id = value.importURL { (source, id) } else { nil }
        default: nil
        }
    }
}

nonisolated enum CollectionError: LocalizedError {
    case incomplete
    var errorDescription: String? { "歌曲列表未完整加载，请重试后再操作" }
}

nonisolated enum PlaylistIdentity {
    static func canonicalID(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value), url.host != nil else { return value }
        let fragment = url.fragment.flatMap { URLComponents(string: $0) }
        let query = (url.queryItems ?? []) + (fragment?.queryItems ?? [])
        for name in ["id", "disstid", "specialid", "songlistid", "playlistId", "dirid"] {
            if let id = query.first(where: { $0.name == name })?.value, !id.isEmpty { return id }
        }
        let last = (fragment?.path.isEmpty == false ? fragment?.path : url.path)?
            .split(separator: "/").last.map(String.init) ?? ""
        let stem = last.replacingOccurrences(of: ".html", with: "")
        return !stem.isEmpty && stem.allSatisfy(\.isNumber) ? stem : value
    }
}

nonisolated struct CollectionAccumulator {
    private(set) var tracks: [MusicTrack] = []
    private(set) var total = 0
    var isComplete: Bool { tracks.count >= total }

    mutating func append(_ page: TrackPage) throws {
        var seen = Set(tracks.map(\.id))
        let additions = page.tracks.filter { seen.insert($0.id).inserted }
        total = max(total, page.total, tracks.count + additions.count)
        guard !additions.isEmpty || tracks.count >= total else { throw CollectionError.incomplete }
        tracks.append(contentsOf: additions)
    }
}

nonisolated extension Array where Element == MusicTrack {
    func matching(_ query: String) -> [MusicTrack] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return self }
        return filter {
            $0.title.localizedCaseInsensitiveContains(term)
                || $0.artist.localizedCaseInsensitiveContains(term)
                || $0.album.localizedCaseInsensitiveContains(term)
        }
    }
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
