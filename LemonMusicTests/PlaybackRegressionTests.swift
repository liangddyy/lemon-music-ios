import Foundation
import AudioStreaming
import Testing
@testable import LemonMusic

@Suite(.serialized)
struct PlaybackRegressionTests {
    private enum RecoveryAction: CaseIterable {
        case resume, next, previous, previousFromStart, selectTrack, selectQueueEntry
    }

    @MainActor @Test(arguments: RecoveryAction.allCases)
    private func userPlaybackRecoversWithoutInterruptionEnded(action: RecoveryAction) async throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AudioCache(container: store.container, root: root)
        let name = "interruption-recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let player = PlaybackController(api: LemonAPIClient(), audioCache: cache, artworkStore: ArtworkStore(), defaults: defaults)
        defer { player.stop(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let songs = try (0..<3).map { try track(id: UUID().uuidString, title: "Song \($0)", artist: "Artist", duration: 20) }
        for song in songs {
            let file = root.appendingPathComponent(UUID().uuidString)
            try silentWAV().write(to: file)
            _ = try cache.storeDownloadedFile(at: file, key: song.id, mimeType: "audio/wav", protectedKey: nil)
        }
        await player.play(songs[1], in: songs)
        for _ in 0..<100 where !player.canSeek { try await Task.sleep(for: .milliseconds(20)) }
        #expect(player.seek(to: action == .previousFromStart ? 1 : 5))
        try await Task.sleep(for: .milliseconds(200))
        player.handleInterruptionBegan()
        let saved = player.position
        #expect(player.isAudioInterrupted)
        #expect(!player.isPlaying)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!player.isPlaying)

        let expectedIndex: Int
        switch action {
        case .resume:
            expectedIndex = 1
            player.resume()
        case .next:
            expectedIndex = 2
            await player.next()
        case .previous:
            expectedIndex = 1
            await player.previous()
        case .previousFromStart:
            expectedIndex = 0
            await player.previous()
        case .selectTrack:
            expectedIndex = 0
            await player.play(songs[0], in: songs)
        case .selectQueueEntry:
            expectedIndex = 0
            await player.playQueueEntry(id: player.queueEntries[0].id)
        }
        for _ in 0..<100 where !player.isPlaying || !player.canSeek || player.isLoadingTrack {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!player.isAudioInterrupted)
        #expect(player.isPlaying)
        #expect(player.canSeek)
        #expect(player.lastError == nil)
        #expect(player.currentIndex == expectedIndex)
        #expect(player.currentTrack?.id == songs[expectedIndex].id)
        if action == .resume { #expect(player.position >= saved - 0.5) }
        else { #expect(player.position < 3) }
        // A late end for the old interruption must not stop the explicitly restarted track.
        player.handleInterruptionEnded(shouldResume: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.isPlaying)
        #expect(player.currentIndex == expectedIndex)
    }

    @MainActor @Test func deniedSessionActivationKeepsInterruptionAndQueueRetryable() async throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AudioCache(container: store.container, root: root)
        let name = "interruption-denied.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let songs = try (0..<2).map { try track(id: UUID().uuidString, title: "Song \($0)", artist: "Artist", duration: 20) }
        var queue = PlaybackQueue()
        queue.replace(with: songs, selecting: songs[0])
        defaults.set(try JSONEncoder().encode(queue), forKey: "lemon.playback.state")
        defaults.set(5.0, forKey: "lemon.playback.position")
        let player = PlaybackController(
            api: LemonAPIClient(), audioCache: cache, artworkStore: ArtworkStore(), defaults: defaults,
            activateSession: { throw URLError(.cannotConnectToHost) }
        )
        defer { player.stop(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        player.handleInterruptionBegan()
        player.resume()
        await player.next()
        await player.previous()
        #expect(player.isAudioInterrupted)
        #expect(!player.isPlaying)
        #expect(!player.isLoadingTrack)
        #expect(player.lastError != nil)
        #expect(player.currentIndex == 0)
        #expect(player.position == 5)
    }

    @MainActor @Test(arguments: [true, false])
    func newerUserActionWinsOverPendingInterruptionResume(skip: Bool) async throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AudioCache(container: store.container, root: root)
        let name = "interruption-skip.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let player = PlaybackController(api: LemonAPIClient(), audioCache: cache, artworkStore: ArtworkStore(), defaults: defaults)
        defer { player.stop(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let songs = try (0..<2).map { try track(id: UUID().uuidString, title: "Song \($0)", artist: "Artist", duration: 20) }
        for song in songs {
            let file = root.appendingPathComponent(UUID().uuidString)
            try silentWAV().write(to: file)
            _ = try cache.storeDownloadedFile(at: file, key: song.id, mimeType: "audio/wav", protectedKey: nil)
        }
        await player.play(songs[0], in: songs)
        for _ in 0..<100 where !player.canSeek { try await Task.sleep(for: .milliseconds(20)) }
        #expect(player.seek(to: 5))
        try await Task.sleep(for: .milliseconds(200))
        player.handleInterruptionBegan()
        if skip {
            player.resume()
            await player.next()
            for _ in 0..<100 where !player.canSeek || !player.isPlaying { try await Task.sleep(for: .milliseconds(20)) }
            #expect(player.currentTrack?.id == songs[1].id)
            #expect(player.currentIndex == 1)
            #expect(player.position < 3)
            #expect(player.isPlaying)
        } else {
            player.handleInterruptionEnded(shouldResume: true)
            player.pause()
            try await Task.sleep(for: .milliseconds(200))
            #expect(player.currentIndex == 0)
            #expect(!player.isPlaying)
            #expect(!player.isLoadingTrack)
        }
        #expect(!player.isAudioInterrupted)
    }

    @MainActor @Test(arguments: [true, false])
    func interruptionPausesUIAndOnlyResumesWhenAllowed(shouldResume: Bool) async throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AudioCache(container: store.container, root: root)
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let player = PlaybackController(api: LemonAPIClient(), audioCache: cache, artworkStore: ArtworkStore(), defaults: defaults)
        defer { player.stop(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let song = try track(id: UUID().uuidString, title: "Song", artist: "Artist", duration: 20)
        let file = root.appendingPathComponent("song.wav")
        try silentWAV().write(to: file)
        _ = try cache.storeDownloadedFile(at: file, key: song.id, mimeType: "audio/wav", protectedKey: nil)
        await player.play(song)
        for _ in 0..<100 where !player.canSeek { try await Task.sleep(for: .milliseconds(50)) }
        #expect(player.seek(to: 4))
        try await Task.sleep(for: .milliseconds(200))
        player.handleInterruptionBegan()
        let saved = player.position
        #expect(player.isAudioInterrupted)
        #expect(!player.isPlaying)
        #expect(!player.canSeek)
        #expect(!player.seek(to: 8))
        player.handlePlayerState(.playing)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!player.isPlaying)
        #expect(player.position == saved)
        player.handleInterruptionEnded(shouldResume: shouldResume)
        for _ in 0..<100 where shouldResume && !player.isPlaying { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!player.isAudioInterrupted)
        #expect(player.isPlaying == shouldResume)
        if !shouldResume { player.resume() }
        for _ in 0..<100 where !player.canSeek { try await Task.sleep(for: .milliseconds(50)) }
        #expect(player.canSeek)
        #expect(player.lastError == nil)
        player.handleInterruptionBegan()
        player.pause()
        player.handleInterruptionEnded(shouldResume: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!player.isPlaying)
        #expect(player.seek(to: 12))
        try await Task.sleep(for: .milliseconds(600))
        #expect(player.position == 12)
        let beforeReset = player.position
        player.handleMediaServicesReset()
        #expect(!player.isPlaying)
        #expect(!player.canSeek)
        #expect(player.currentTrack?.id == song.id)
        player.resume()
        for _ in 0..<100 where !player.canSeek { try await Task.sleep(for: .milliseconds(50)) }
        #expect(player.canSeek)
        #expect(player.position >= beforeReset - 0.5)
    }

    @MainActor @Test func restoredQueueLoadsAudioOnFirstResumeAndKeepsSavedPosition() async throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AudioCache(container: store.container, root: root)
        let name = "restore-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let song = try track(id: UUID().uuidString, title: "Restored", artist: "Artist", duration: 20)
        let file = root.appendingPathComponent("cached.wav")
        try UITestAudio.silence().write(to: file)
        _ = try cache.storeDownloadedFile(at: file, key: song.id, mimeType: "audio/wav", protectedKey: nil)
        var queue = PlaybackQueue()
        queue.replace(with: [song], selecting: song)
        defaults.set(try JSONEncoder().encode(queue), forKey: "lemon.playback.state")
        defaults.set(5.0, forKey: "lemon.playback.position")
        let player = PlaybackController(api: LemonAPIClient(), audioCache: cache, artworkStore: ArtworkStore(), defaults: defaults)
        defer { player.stop(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(player.currentTrack?.id == song.id)
        #expect(player.position == 5)
        #expect(!player.isPlaying)
        player.resume()
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<100 where !player.isPlaying { try await Task.sleep(for: .milliseconds(50)) }
        #expect(player.isPlaying)
        #expect(player.lastError == nil)
        #expect(player.position >= 4.5)
        #expect(player.audioCacheState(for: song) == .cached)
    }

    @MainActor @Test func restoredQueueFailureProvidesReasonInsteadOfResumingEmptyEngine() async throws {
        let store = try CacheStore(inMemory: true)
        let cache = AudioCache(container: store.container)
        let name = "restore-failure.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let song = try track(id: UUID().uuidString, title: "Unavailable", artist: "Artist")
        var queue = PlaybackQueue()
        queue.replace(with: [song], selecting: song)
        defaults.set(try JSONEncoder().encode(queue), forKey: "lemon.playback.state")
        let player = PlaybackController(api: LemonAPIClient(), audioCache: cache, artworkStore: ArtworkStore(), defaults: defaults)
        defer { player.stop(); defaults.removePersistentDomain(forName: name) }
        player.resume()
        for _ in 0..<100 where player.lastError == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(player.lastError?.contains("服务器地址") == true)
        #expect(!player.isPlaying)
        #expect(!player.isLoadingTrack)
    }

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
            player.stop()
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

    @MainActor @Test(arguments: [PlaybackMode.sequential, .shuffled, .repeatOne])
    func naturalEndAdvancesOrRepeatsAndStartsAudio(mode: PlaybackMode) async throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AudioCache(container: store.container, root: root)
        let name = "natural-end-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let player = PlaybackController(
            api: LemonAPIClient(), audioCache: cache, artworkStore: ArtworkStore(), defaults: defaults
        )
        let first = try track(id: UUID().uuidString, title: "First", artist: "Artist", duration: 2)
        let second = try track(id: UUID().uuidString, title: "Second", artist: "Artist", duration: 20)
        defer {
            player.stop()
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        for song in [first, second] {
            let file = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            try silentWAV(seconds: UInt32(song.duration)).write(to: file)
            _ = try cache.storeDownloadedFile(at: file, key: song.id, mimeType: "audio/wav", protectedKey: nil)
        }
        var startedTracks: [String] = []
        player.onTrackChanged = {
            if let id = player.currentTrack?.id { startedTracks.append(id) }
        }
        player.setMode(mode)
        await player.play(first, in: [first, second])
        for _ in 0..<200 where startedTracks.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let expected = mode == .repeatOne ? first : second
        #expect(Array(startedTracks.prefix(2)) == [first.id, expected.id])
        #expect(player.currentTrack?.id == expected.id)
        for _ in 0..<100 where !player.isPlaying || player.isLoadingTrack || player.position == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.isPlaying)
        #expect(player.position > 0)
        #expect(player.lastError == nil)
        #expect(player.currentIndex == (mode == .repeatOne ? 0 : 1))
    }

    private func silentWAV(seconds: UInt32 = 20) -> Data {
        let sampleRate: UInt32 = 44_100
        let byteCount = sampleRate * 2 * seconds
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
