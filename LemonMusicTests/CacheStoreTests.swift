import Foundation
import Testing
@testable import LemonMusic

@MainActor
struct CacheStoreTests {
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

    private func temporaryAudioFile(byte: UInt8, count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: byte, count: count).write(to: url)
        return url
    }
}
