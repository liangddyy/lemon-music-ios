import Foundation
import Testing
@testable import LemonMusic

struct PlaybackRegressionTests {
    @Test func ignoresOldAndDuplicateEndEventsDuringABCDSelection() {
        var state = PlaybackRequestState()
        let a = state.begin()
        let b = state.begin()
        let oldAEnded = state.consumeEnd(for: a)
        #expect(!oldAEnded)
        #expect(state.isCurrent(b))
        let c = state.begin()
        let oldBEnded = state.consumeEnd(for: b)
        #expect(!oldBEnded)
        #expect(state.isCurrent(c))
        let cEnded = state.consumeEnd(for: c)
        #expect(cEnded)
        let duplicateCEnded = state.consumeEnd(for: c)
        #expect(!duplicateCEnded)
        let d = state.begin()
        let lateCEnded = state.consumeEnd(for: c)
        #expect(!lateCEnded)
        #expect(state.isCurrent(d))
    }

    @Test func matchesTitleAndArtistButRejectsLiveAndCoverVersions() throws {
        let online = try track(id: "online", title: "夜曲", artist: "周杰伦", local: false)
        let wrongArtist = try track(id: "cover", title: "夜曲", artist: "其他歌手")
        let live = try track(id: "live", title: "夜曲 (Live)", artist: "周杰伦")
        let correct = try track(id: "local", title: "夜曲", artist: "周杰伦")
        let result = LocalTrackMatcher.bestMatch(for: online, in: [wrongArtist, live, correct])
        #expect(result?.id == correct.id)
        #expect(LocalTrackMatcher.bestMatch(for: online, in: [wrongArtist, live]) == nil)
    }

    @Test func matchesArtistListsAcrossSeparatorsAndRejectsDifferentDuration() throws {
        let online = try track(id: "online", title: "Song", artist: "Artist A / Artist B", local: false)
        let same = try track(id: "same", title: "ＳＯＮＧ", artist: "artist b、artist a")
        let wrongDuration = try track(id: "duration", title: "Song", artist: "Artist A / Artist B", duration: 250)
        #expect(LocalTrackMatcher.bestMatch(for: online, in: [same])?.id == same.id)
        #expect(LocalTrackMatcher.bestMatch(for: online, in: [wrongDuration]) == nil)
    }

    @Test func playlistSnapshotsFollowTrackKeysRatherThanDictionaryOrder() throws {
        let a = try track(id: "a", title: "A", artist: "Artist")
        let b = try track(id: "b", title: "B", artist: "Artist")
        let playlist = try #require(MusicPlaylist(json: .object([
            "id": .string("playlist"),
            "trackKeys": .array([.string(b.id), .string(a.id)]),
            "trackSnapshots": .object([a.id: a.snapshotJSON, b.id: b.snapshotJSON]),
            "coverUrl": .string("https://example.com/cover.jpg"),
        ])))
        #expect(playlist.tracks.map(\.id) == [b.id, a.id])
        #expect(playlist.artworkURL != nil)
    }

    @Test func onlineRankKeepsCoverProviderAndDuration() throws {
        let rank = try #require(MusicPlaylist(json: .object([
            "id": .string("rank-1"), "name": .string("榜单"), "cover": .string("https://example.com/rank.jpg"),
        ]), defaultSource: "wy"))
        #expect(rank.id == "wy:rank-1")
        #expect(rank.providerID == "rank-1")
        #expect(rank.artworkURL == "https://example.com/rank.jpg")
        let song = try #require(MusicTrack(json: .object([
            "songId": .string("1"), "name": .string("Song"), "interval": .string("05:19"),
        ]), defaultSource: "wy"))
        #expect(song.duration == 319)
    }

    @MainActor @Test func rapidSelectionKeepsActualPlayerOnSelectedCachedTrack() async throws {
        let store = try CacheStore(inMemory: true)
        let cache = AudioCache(container: store.container)
        let player = PlaybackController(
            api: LemonAPIClient(), audioCache: cache, artworkStore: ArtworkStore(),
            defaults: UserDefaults(suiteName: "lemon.playback-tests.\(UUID())")!
        )
        let prefix = UUID().uuidString
        let songs = try ["A", "B", "C", "D"].map {
            try track(id: "\(prefix)-\($0)", title: $0, artist: "Artist", duration: 20)
        }
        defer {
            player.pause()
            songs.forEach { cache.remove(for: $0.id) }
        }
        let audio = silentWAV()
        for song in songs {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try audio.write(to: temporary)
            _ = try cache.storeDownloadedFile(
                at: temporary, key: song.id, mimeType: "audio/wav", protectedKey: nil
            )
        }
        await player.play(songs[0], in: songs)
        try await Task.sleep(for: .milliseconds(150))
        await player.play(songs[1], in: songs)
        try await Task.sleep(for: .milliseconds(150))
        #expect(player.currentTrack?.id == songs[1].id)
        #expect(player.currentIndex == 1)
        await player.play(songs[2], in: songs)
        await player.play(songs[3], in: songs)
        try await Task.sleep(for: .milliseconds(500))
        // Simulator audio startup is asynchronous, especially while other targets are building.
        for _ in 0..<100 where !player.isPlaying {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(player.currentTrack?.id == songs[3].id)
        #expect(player.currentIndex == 3)
        #expect(player.audioCacheState(for: songs[3]) == .cached)
        #expect(player.lastError == nil)
        #expect(player.isPlaying)
    }

    private func silentWAV() -> Data {
        let sampleRate: UInt32 = 44_100
        let byteCount = sampleRate * 2 * 20
        var data = Data("RIFF".utf8)
        append(byteCount + 36, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(sampleRate, to: &data)
        append(sampleRate * 2, to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(byteCount, to: &data)
        data.append(Data(repeating: 0, count: Int(byteCount)))
        return data
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func track(
        id: String, title: String, artist: String, local: Bool = true, duration: Double = 200
    ) throws -> MusicTrack {
        var json: [String: JSONValue] = [
            "id": .string(id), "title": .string(title), "artist": .string(artist), "duration": .number(duration),
        ]
        if local { json["filePath"] = .string("/music/\(id).mp3") }
        else { json["source"] = .string("wy") }
        return try #require(MusicTrack(json: .object(json)))
    }
}
