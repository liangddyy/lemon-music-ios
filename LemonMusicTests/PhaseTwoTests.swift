import Foundation
import Testing
import UIKit
@testable import LemonMusic

@Suite(.serialized)
struct PhaseTwoTests {
    @Test func modesCycleAndUseAvailableSymbols() {
        #expect(PlaybackMode.sequential.next == .shuffled)
        #expect(PlaybackMode.shuffled.next == .repeatOne)
        #expect(PlaybackMode.repeatOne.next == .sequential)
        for mode in PlaybackMode.allCases {
            #expect(UIImage(systemName: mode.symbol) != nil)
        }
    }

    @Test func sequentialWrapsAndRepeatOneOnlyRepeatsNaturalEnd() throws {
        let tracks = try songs(3)
        var queue = PlaybackQueue()
        queue.replace(with: tracks, selecting: tracks[2])
        queue.advance(natural: true)
        #expect(queue.current?.track == tracks[0])
        queue.retreat()
        #expect(queue.current?.track == tracks[2])
        queue.setMode(.repeatOne)
        queue.advance(natural: true)
        #expect(queue.current?.track == tracks[2])
        queue.advance(natural: false)
        #expect(queue.current?.track == tracks[0])
    }

    @Test func shuffleVisitsEveryEntryAndAvoidsRepeatAtRoundBoundary() throws {
        let tracks = try songs(5)
        var queue = PlaybackQueue()
        queue.replace(with: tracks, selecting: tracks[2])
        queue.setMode(.shuffled)
        var visited = Set<String>()
        for _ in 0..<tracks.count {
            visited.insert(try #require(queue.current?.track.id))
            if visited.count < tracks.count { queue.advance(natural: true) }
        }
        #expect(visited == Set(tracks.map(\.id)))
        let last = queue.current?.track.id
        queue.advance(natural: true)
        #expect(queue.current?.track.id != last)
    }

    @Test func editsAndDuplicateOccurrencesSurviveShuffleAndPersistence() throws {
        let tracks = try songs(4)
        var queue = PlaybackQueue()
        queue.replace(with: [tracks[0], tracks[1], tracks[0]], selecting: tracks[1])
        let currentID = queue.current?.id
        queue.setMode(.shuffled)
        queue.insertNext(tracks[2])
        queue.append([tracks[3]])
        queue.move(from: IndexSet(integer: 1), to: queue.tracks.count)
        #expect(queue.current?.id == currentID)
        let removedID = queue.ordered[1].id
        queue.remove(at: IndexSet(integer: 1))
        #expect(!queue.original.contains { $0.id == removedID })
        queue.setMode(.repeatOne)
        #expect(queue.current?.id == currentID)
        #expect(queue.tracks.contains(tracks[2]))
        #expect(queue.tracks.contains(tracks[3]))
        let restored = try JSONDecoder().decode(PlaybackQueue.self, from: JSONEncoder().encode(queue))
        #expect(restored.current?.id == currentID)
        #expect(restored.mode == .repeatOne)
        #expect(restored.tracks == queue.tracks)
    }

    @Test func emptyAndSingleTrackQueuesAllowAllModes() throws {
        var queue = PlaybackQueue()
        queue.setMode(.shuffled)
        queue.advance(natural: true)
        #expect(queue.tracks.isEmpty)
        let song = try songs(1)[0]
        queue.replace(with: [song], selecting: song)
        for mode in PlaybackMode.allCases {
            queue.setMode(mode)
            queue.advance(natural: true)
            queue.advance(natural: false)
            #expect(queue.current?.track == song)
        }
    }

    @Test func collectionRejectsIncompleteAndRepeatedPages() throws {
        let tracks = try songs(3)
        var result = CollectionAccumulator()
        try result.append(TrackPage(tracks: Array(tracks.prefix(2)), total: 3))
        #expect(!result.isComplete)
        #expect(throws: CollectionError.self) {
            try result.append(TrackPage(tracks: Array(tracks.prefix(2)), total: 3))
        }
        try result.append(TrackPage(tracks: [tracks[2]], total: 3))
        #expect(result.isComplete)
        #expect(result.tracks == tracks)
    }

    @Test func collectionSearchDoesNotModifyOriginalQueue() throws {
        let tracks = try songs(3)
        #expect(tracks.matching("song 1").map(\.id) == [tracks[1].id])
        #expect(tracks.matching("ARTIST").count == 3)
        #expect(tracks.matching(" Album ").count == 3)
        #expect(tracks.matching("").count == 3)
        #expect(tracks.count == 3)
    }

    @Test func importedPlaylistPreservesWebFieldsAndOldCacheDecodes() throws {
        let json: JSONValue = .object([
            "id": .string("imported"), "name": .string("收藏歌单"), "playlistType": .string("imported"),
            "importSource": .string("wy"), "importUrl": .string("123"),
            "remoteAutoSync": .bool(false), "coverMode": .string("custom"), "extraWebField": .string("keep"),
            "lastRemoteSyncedAt": .number(1_790_000_000_000),
        ])
        let playlist = try #require(MusicPlaylist(json: json))
        #expect(playlist.isImported)
        #expect(playlist.json["playlistType"] == .string("imported"))
        #expect(playlist.json["extraWebField"] == .string("keep"))
        #expect(playlist.json["remoteAutoSync"] == .bool(false))
        let restored = try JSONDecoder().decode(MusicPlaylist.self, from: JSONEncoder().encode(playlist))
        #expect(restored == playlist)
        let legacy = Data(#"{"id":"old","name":"旧歌单","tracks":[],"createdAt":1}"#.utf8)
        let old = try JSONDecoder().decode(MusicPlaylist.self, from: legacy)
        #expect(!old.isImported)
        #expect(old.json["playlistType"] == .string("custom"))
    }

    @Test func providerOnlyIDSurvivesSongSnapshotAndPlaylistURLsNormalize() throws {
        let track = try #require(MusicTrack(json: .object(["id": .string("123"), "source": .string("wy"), "name": .string("Song")])))
        let restored = try #require(MusicTrack(json: track.snapshotJSON))
        #expect(restored.locator.songID == "123")
        #expect(restored.id == track.id)
        #expect(PlaylistIdentity.canonicalID("https://music.163.com/#/playlist?id=123") == "123")
        #expect(PlaylistIdentity.canonicalID("https://y.qq.com/n/yqq/playlist/456.html") == "456")
        var imported = MusicPlaylist(name: "Imported")
        imported.preservedFields = [
            "playlistType": .string("imported"), "importSource": .string("wy"),
            "importUrl": .string("https://music.163.com/#/playlist?id=123"),
        ]
        let online = OnlineCollection(kind: .playlist, source: "wy", id: "123", title: "Online")
        #expect(CollectionSource.playlist(imported).key == CollectionSource.online(online).key)
    }

    @Test func downloadPayloadPreservesProviderIDsAndDoesNotDowngrade() throws {
        let track = try #require(MusicTrack(json: .object([
            "songId": .string("a"), "source": .string("qq"), "name": .string("Song"),
            "musicId": .string("music"), "rid": .string("rid"), "dcTargetId": .string("dc"),
            "strMediaMid": .string("media"), "qualitys": .array([.string("flac")]),
        ])))
        let payload = track.downloadPayload(quality: .flac, batchID: "batch")
        #expect(payload["musicId"] == .string("music"))
        #expect(payload["strMediaMid"] == .string("media"))
        #expect(payload["quality"] == .string("flac"))
        #expect(payload["qualityPolicy"] == .string("none"))
        #expect(payload["autoCascade"] == .bool(false))
        #expect(payload["qualitys"] == .array([.string("flac")]))
        let task = try #require(NASDownloadTask(json: .object([
            "id": .string("task"), "status": .string("await_exist"), "progress": .number(20),
        ])))
        #expect(task.statusTitle.contains("同名"))
        #expect(task.progress == 0.2)
    }

    @Test func opaqueResumeRequestsAreExcludedFromMetadataSnapshots() throws {
        var item = CollectionCacheItem(track: try songs(1)[0])
        item.resumeData = Data("private request".utf8)
        let encoded = try JSONEncoder().encode(item)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["resumeData"] == nil)
        let restored = try JSONDecoder().decode(CollectionCacheItem.self, from: encoded)
        #expect(restored.resumeData == nil)
        #expect(restored.id == item.id)
    }

    @MainActor @Test func capacityAdmissionPreservesBatchTargetsAndRejectsDamagedAudio() throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = AudioCache(container: store.container, root: root)
        let oldLimit = cache.maxBytes
        defer { cache.maxBytes = oldLimit; try? FileManager.default.removeItem(at: root) }
        cache.maxBytes = 4_096
        let file = root.appendingPathComponent("first")
        var audio = Data("RIFF".utf8)
        audio.append(Data(repeating: 0, count: 2_044))
        try audio.write(to: file)
        _ = try cache.storeDownloadedFile(at: file, key: "first", mimeType: "audio/wav", protectedKey: nil)
        cache.protectedKeys = ["first"]
        #expect(throws: AudioCache.StorageError.self) { try cache.makeRoom(for: 3_000, replacing: "second") }
        #expect(cache.cachedURL(for: "first") != nil)
        let damaged = root.appendingPathComponent("damaged")
        try Data(repeating: 65, count: 2_048).write(to: damaged)
        #expect(throws: URLError.self) { try AudioCache.validateAudioFile(at: damaged, mimeType: "audio/mpeg") }
        cache.protectedKeys = []
        try cache.makeRoom(for: 3_000, replacing: "second")
        #expect(cache.cachedURL(for: "first") == nil)
    }

    @MainActor @Test func cacheTasksDeduplicatePersistCancelAndRemainAccountScoped() async throws {
        let store = try CacheStore(inMemory: true)
        let cache = AudioCache(container: store.container)
        let coordinator = CollectionCacheCoordinator(api: LemonAPIClient(), audioCache: cache, store: store, background: false, monitorNetwork: false)
        let tracks = try songs(2)
        coordinator.configure(account: "server|user", activate: false)
        coordinator.start(key: "collection", title: "Test", tracks: [tracks[0], tracks[0], tracks[1]], allowsCellular: false)
        #expect(coordinator.batches["collection"]?.items.count == 2)
        let saved = try #require(store.value([String: CollectionCacheBatch].self, for: "cache-batches.server|user"))
        #expect(saved["collection"]?.allowsCellular == false)
        coordinator.pause(key: "collection")
        #expect(coordinator.batches["collection"]?.paused == true)
        coordinator.resume(key: "collection", allowsCellular: true)
        #expect(coordinator.batches["collection"]?.allowsCellular == true)
        coordinator.cancel(key: "collection")
        #expect(coordinator.batches["collection"]?.cancelled == true)
        #expect(cache.protectedKeys.isEmpty)
        coordinator.reset()
        coordinator.configure(account: "other|user", activate: false)
        #expect(coordinator.batches.isEmpty)
        coordinator.reset()
    }

    private func songs(_ count: Int) throws -> [MusicTrack] {
        try (0..<count).map {
            try #require(MusicTrack(json: .object([
                "songId": .string("\($0)"), "source": .string("wy"),
                "name": .string("Song \($0)"), "singer": .string("Artist"), "album": .string("Album"),
            ])))
        }
    }
}
