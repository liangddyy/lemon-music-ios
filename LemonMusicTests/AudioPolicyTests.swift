import Foundation
import Testing
@testable import LemonMusic

struct AudioPolicyTests {
    @MainActor @Test func saverDefaultsOnPersistsAndOnlyOverridesCellular() {
        let name = "audio-policy-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = AudioPlaybackPolicy(defaults: defaults)
        #expect(policy.dataSaverEnabled)
        #expect(policy.qualityOverride == nil)
        policy.updateNetwork(cellular: true)
        #expect(policy.qualityOverride == "128k")
        policy.dataSaverEnabled = false
        #expect(policy.qualityOverride == nil)
        #expect(!AudioPlaybackPolicy(defaults: defaults).dataSaverEnabled)
        policy.dataSaverEnabled = true
        policy.updateNetwork(cellular: false)
        #expect(policy.qualityOverride == nil)
    }

    @Test func onlineVariantsAreDistinctButLocalFilesKeepOriginalKey() throws {
        let online = try #require(MusicTrack(json: .object([
            "source": .string("wy"), "songId": .string("1"), "name": .string("Song"),
        ])))
        let local = try #require(MusicTrack(json: .object(["filePath": .string("/music/song.mp3")])))
        let low = AudioVariant.key(for: online, quality: "128k")
        let high = AudioVariant.key(for: online, quality: "320k")
        #expect(low != high)
        #expect(AudioVariant.matches(low, trackID: online.id))
        #expect(!AudioVariant.matches(low, trackID: "other"))
        #expect(AudioVariant.key(for: local, quality: "128k") == local.id)
    }

    @MainActor @Test func anyCompleteOfflineVariantIsReusedWithoutMixingPartialKeys() throws {
        let store = try CacheStore(inMemory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AudioCache(container: store.container, root: root)
        let online = try #require(MusicTrack(json: .object(["source": .string("wy"), "songId": .string("1")])))
        let low = AudioVariant.key(for: online, quality: "128k")
        let high = AudioVariant.key(for: online, quality: "320k")
        cache.streamCache.configure(key: high, totalLength: 4_096, mimeType: "audio/mpeg", headerLength: 0, remoteDataOffset: 0)
        cache.streamCache.store(data: Data(repeating: 65, count: 2_048), at: 0, for: high)
        #expect(cache.partialProgress(for: low) == nil)
        #expect(cache.partialProgress(for: high)?.downloaded == 2_048)
        let file = root.appendingPathComponent("full")
        try Data(repeating: 66, count: 2_048).write(to: file)
        _ = try cache.storeDownloadedFile(at: file, key: high, mimeType: "audio/mpeg", protectedKey: nil)
        #expect(cache.availableCache(for: online)?.key == high)
        #expect(cache.cachedURL(for: low) == nil)
    }
}
