import Foundation
import Testing
@testable import LemonMusic

struct AudioPolicyTests {
    @Test func staleDownloadCannotBeWrittenUnderNewQualityOrTranscodeVariant() throws {
        let track = try #require(MusicTrack(json: .object(["filePath": .string("/music/song.flac")])))
        var item = CollectionCacheItem(track: track)
        item.smooth = false
        let tag = CacheTransferTag(
            account: "test", key: "batch", batchID: UUID(), itemID: item.id,
            transferID: UUID(), allowsCellular: false, quality: nil, smooth: false
        )
        #expect(tag.matchesVariant(of: item))
        item.smooth = true
        #expect(!tag.matchesVariant(of: item))
        item.smooth = false
        item.quality = "128k"
        #expect(!tag.matchesVariant(of: item))
    }

    @MainActor @Test func clearingAudioCacheKeepsPolicyButLogoutResetsServerSettings() async throws {
        let model = try AppModel(inMemory: true)
        model.audioPolicy.applyServerSettings(ServerPlaybackSettings(quality: "flac", smooth: true))
        model.clearAudioCache()
        #expect(model.audioPolicy.serverSettings.smooth)
        await model.logout()
        #expect(!model.audioPolicy.serverSettings.smooth)
    }

    @MainActor @Test func serverSmoothCapsOnlineQualityAndPersists() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let policy = AudioPlaybackPolicy(defaults: defaults)
        policy.dataSaverEnabled = false
        policy.applyServerSettings(ServerPlaybackSettings(quality: "flac", smooth: true))
        #expect(policy.qualityOverride == "128k")
        #expect(AudioPlaybackPolicy(defaults: defaults).serverSettings.smooth)
        policy.applyServerSettings(ServerPlaybackSettings(quality: "flac", smooth: false))
        #expect(policy.qualityOverride == nil)
    }

    @Test func aacLocalVariantNeverUsesOriginalCacheIdentity() throws {
        let flac = try #require(MusicTrack(json: .object(["filePath": .string("/music/song.flac")])))
        let original = AudioVariant.key(for: flac, quality: nil)
        let aac = AudioVariant.key(for: flac, quality: nil, smooth: true)
        #expect(original != aac)
        #expect(AudioVariant.matches(aac, trackID: flac.id))
        let mp3 = try #require(MusicTrack(json: .object(["filePath": .string("/music/song.mp3")])))
        #expect(AudioVariant.key(for: mp3, quality: nil, smooth: true) == mp3.id)
        let dsd = try #require(MusicTrack(json: .object(["filePath": .string("/music/song.dsf")])))
        #expect(AudioVariant.usesAAC(for: dsd, smooth: false))
    }

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
        let name = "audio-cache-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let cache = AudioCache(container: store.container, root: root, defaults: defaults)
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
