import Foundation

nonisolated enum LocalTrackMatcher {
    static func bestMatch(for online: MusicTrack, in candidates: [MusicTrack]) -> MusicTrack? {
        let title = normalized(online.title)
        let artists = artistNames(online.artist)
        guard !title.isEmpty, !artists.isEmpty, online.artist != "未知歌手" else { return nil }
        let matches = candidates.filter { candidate in
            guard candidate.locator.kind == .local,
                  normalized(candidate.title) == title,
                  artistNames(candidate.artist) == artists else { return false }
            return online.duration <= 0 || candidate.duration <= 0 || abs(online.duration - candidate.duration) <= 8
        }
        return matches.sorted { lhs, rhs in
            let lhsAlbum = normalized(lhs.album) == normalized(online.album)
            let rhsAlbum = normalized(rhs.album) == normalized(online.album)
            if lhsAlbum != rhsAlbum { return lhsAlbum }
            return lhs.id < rhs.id
        }.first
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func artistNames(_ value: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: "/、,，;&＆")
        return Set(value.components(separatedBy: separators).map(normalized).filter { !$0.isEmpty })
    }
}
