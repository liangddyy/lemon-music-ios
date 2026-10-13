import Foundation
import Observation
import Testing
@testable import LemonMusic

@MainActor
struct CacheStoreTests {
    @Test func cacheLimitIsObservablePersistsAndEvictsOldestFile() throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let cache = AudioCache(container: store.container, root: root, defaults: defaults)
        cache.maxBytes = 4_096
        for key in ["first", "second"] {
            _ = try cache.storeDownloadedFile(
                at: temporaryAudioFile(byte: 65, count: 2_048), key: key, mimeType: "audio/mpeg", protectedKey: nil
            )
        }
        nonisolated(unsafe) var changed = false
        withObservationTracking { _ = cache.maxBytes } onChange: { changed = true }
        cache.maxBytes = 2_048
        #expect(changed)
        #expect(cache.usedBytes() == 2_048)
        #expect(cache.cachedURL(for: "first") == nil)
        #expect(cache.cachedURL(for: "second") != nil)
        #expect(AudioCache(container: store.container, root: root, defaults: defaults).maxBytes == 2_048)
    }

    @Test func disablingAutomaticCacheStopsWritesButKeepsExistingPrefixAndManualCache() throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let cache = AudioCache(container: store.container, root: root, defaults: defaults)
        let stream = cache.streamCache
        stream.configure(key: "song", totalLength: 4_096, mimeType: "audio/mpeg", headerLength: 0, remoteDataOffset: 0)
        stream.store(data: Data(repeating: 65, count: 2_048), at: 0, for: "song")
        cache.automaticCachingEnabled = false
        stream.store(data: Data(repeating: 66, count: 2_048), at: 2_048, for: "song")
        #expect(stream.cachedByteCount(for: "song") == 2_048)
        #expect(stream.data(for: "song", offset: 0, length: 2_048)?.count == 2_048)
        #expect(!AudioCache(container: store.container, root: root, defaults: defaults).automaticCachingEnabled)
        _ = try cache.storeDownloadedFile(at: temporaryAudioFile(byte: 67, count: 2_048), key: "manual", mimeType: "audio/mpeg", protectedKey: nil)
        #expect(cache.cachedURL(for: "manual") != nil)
    }

    @Test func originalAndAACFilesAreSelectedByCurrentLocalPolicy() throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AudioCache(container: store.container, root: root)
        let track = try #require(MusicTrack(json: .object(["filePath": .string("/music/song.flac")])))
        _ = try cache.storeDownloadedFile(at: temporaryAudioFile(byte: 65, count: 2_048), key: track.id, mimeType: "audio/flac", protectedKey: nil)
        #expect(cache.availableCache(for: track, smooth: true) == nil)
        let aac = AudioVariant.key(for: track, quality: nil, smooth: true)
        _ = try cache.storeDownloadedFile(at: temporaryAudioFile(byte: 66, count: 2_048), key: aac, mimeType: "audio/mp4", protectedKey: nil)
        #expect(cache.availableCache(for: track, smooth: true)?.key == aac)
        #expect(cache.availableCache(for: track, smooth: false)?.key == track.id)
    }

    @Test func staleWhileRevalidateKeepsExpiredPayloadReadable() throws {
        let store = try CacheStore(inMemory: true)
        store.save(["cached"], for: "key", ttl: -1)
        let stale: [String]? = store.value([String].self, for: "key", allowExpired: true)
        let fresh: [String]? = store.value([String].self, for: "key", allowExpired: false)
        #expect(stale == ["cached"])
        #expect(fresh == nil)
    }

    @Test func audioCacheStoresReplacesAndRemovesCorruptedFiles() throws {
        let store = try CacheStore(inMemory: true)
        let cache = AudioCache(container: store.container)
        let key = "test-\(UUID().uuidString)"
        defer { cache.remove(for: key) }

        let first = try temporaryAudioFile(byte: 0x11, count: 2_048)
        _ = try cache.storeDownloadedFile(
            at: first,
            key: key,
            mimeType: "audio/mpeg",
            expectedByteCount: 2_048,
            protectedKey: nil
        )
        #expect(cache.cachedURL(for: key) != nil)

        let replacement = try temporaryAudioFile(byte: 0x22, count: 4_096)
        let replacementURL = try cache.storeDownloadedFile(
            at: replacement,
            key: key,
            mimeType: "audio/mpeg",
            expectedByteCount: 4_096,
            protectedKey: nil
        )
        let stored = try Data(contentsOf: replacementURL)
        #expect(stored.count == 4_096)
        #expect(stored.first == 0x22)

        try Data(repeating: 0x33, count: 128).write(to: replacementURL)
        #expect(cache.cachedURL(for: key) == nil)
    }

    @Test func audioCacheRejectsIncompleteDownloads() throws {
        let store = try CacheStore(inMemory: true)
        let cache = AudioCache(container: store.container)
        let key = "test-\(UUID().uuidString)"
        let file = try temporaryAudioFile(byte: 0x44, count: 2_048)
        defer {
            try? FileManager.default.removeItem(at: file)
            cache.remove(for: key)
        }

        do {
            _ = try cache.storeDownloadedFile(
                at: file,
                key: key,
                mimeType: "audio/mpeg",
                expectedByteCount: 4_096,
                protectedKey: nil
            )
            Issue.record("不完整音频不应写入缓存")
        } catch {
            #expect(cache.cachedURL(for: key) == nil)
        }
    }

    @Test func progressiveCacheReusesContiguousPrefixAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("progressive-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "online:wy:song"
        let firstHalf = Data(repeating: 0x55, count: 2_048)

        let first = ProgressiveAudioCache(directory: directory)
        first.configure(
            key: key,
            totalLength: 4_096,
            mimeType: "audio/mpeg",
            headerLength: 0,
            remoteDataOffset: 0
        )
        first.store(data: firstHalf, at: 0, for: key)
        #expect(first.cachedByteCount(for: key) == 2_048)

        let restored = ProgressiveAudioCache(directory: directory)
        restored.configure(
            key: key,
            totalLength: 4_096,
            mimeType: "audio/mpeg",
            headerLength: 0,
            remoteDataOffset: 0
        )
        #expect(restored.cachedByteCount(for: key) == 2_048)
        #expect(restored.data(for: key, offset: 0, length: 2_048) == firstHalf)

        var completion: ProgressiveAudioCache.Completion?
        restored.onComplete = { completion = $0 }
        restored.store(data: Data(repeating: 0x66, count: 2_048), at: 2_048, for: key)
        restored.complete(key: key)
        #expect(completion?.byteCount == 4_096)
    }

    private func temporaryAudioFile(byte: UInt8, count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: byte, count: count).write(to: url)
        return url
    }
}
