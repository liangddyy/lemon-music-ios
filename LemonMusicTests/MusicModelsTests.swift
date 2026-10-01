import Testing
@testable import LemonMusic

struct MusicModelsTests {
    @Test func decodesLocalTrack() throws {
        let json: JSONValue = .object([
            "trackId": .string("8bb5"),
            "filePath": .string("/music/Artist/Album/song.flac"),
            "title": .string("Song"),
            "artist": .string("Artist"),
            "album": .string("Album"),
            "duration": .number(188),
            "format": .string("flac"),
        ])
        let track = try #require(MusicTrack(json: json))
        #expect(track.id == "local:8bb5")
        #expect(track.locator.kind == .local)
        #expect(track.duration == 188)
    }

    @Test func decodesOnlineTrackAndKeepsProviderIdentifiers() throws {
        let json: JSONValue = .object([
            "songmid": .string("mid-1"),
            "name": .string("Online Song"),
            "singer": .string("Singer"),
            "source": .string("tx"),
        ])
        let track = try #require(MusicTrack(json: json))
        #expect(track.id == "online:tx:mid-1")
        #expect(track.locator.kind == .online)
        #expect(track.locator.identifiers["songmid"] == "mid-1")
    }

    @Test func playlistSnapshotRoundTrip() throws {
        let track = try #require(MusicTrack(json: .object([
            "trackId": .string("track-1"),
            "filePath": .string("/music/song.mp3"),
            "title": .string("Song"),
        ])))
        let playlist = MusicPlaylist(id: "playlist-1", name: "收藏", tracks: [track])
        let decoded = try #require(MusicPlaylist(json: playlist.json))
        #expect(decoded.id == playlist.id)
        #expect(decoded.tracks == [track])
    }

    @Test func legacyLocalTrackUsesFilePathForPlaybackWhenTrackIDIsMissing() throws {
        let track = try #require(MusicTrack(json: .object([
            "filePath": .string("/music/legacy.mp3"),
            "title": .string("Legacy"),
        ])))
        #expect(track.id == "local:/music/legacy.mp3")
        #expect(track.locator.trackID == nil)
        #expect(track.locator.filePath == "/music/legacy.mp3")
    }
}
