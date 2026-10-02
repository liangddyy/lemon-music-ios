import Foundation
import XCTest
@testable import LemonMusic

final class BackgroundCacheTests: XCTestCase {
    @MainActor func testDownloadsThroughRealBackgroundSessionAndCoalescesAcrossCollections() async throws {
        try await requireFixture()
        let environment = try await makeEnvironment()
        defer { environment.coordinator.reset(); try? FileManager.default.removeItem(at: environment.root) }
        let track = try song()
        environment.coordinator.start(key: "one", title: "One", tracks: [track], allowsCellular: true)
        environment.coordinator.start(key: "two", title: "Two", tracks: [track], allowsCellular: true)
        for _ in 0..<200 {
            if environment.coordinator.batches["one"]?.isFinished == true,
               environment.coordinator.batches["two"]?.isFinished == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(environment.coordinator.batches["one"]?.isFinished == true)
        XCTAssertTrue(environment.coordinator.batches["two"]?.isFinished == true)
        XCTAssertNotNil(environment.cache.availableCache(for: track))
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18763/stats")!)
        let counts = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(counts[track.locator.songID!], 1)
    }

    @MainActor func testWiFiConsentAndCancellationPreventLateCacheWrites() async throws {
        try await requireFixture()
        let environment = try await makeEnvironment()
        defer { environment.coordinator.reset(); try? FileManager.default.removeItem(at: environment.root) }
        let track = try song()
        environment.coordinator.networkChanged(connected: true, cellular: true)
        environment.coordinator.start(key: "one", title: "One", tracks: [track], allowsCellular: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(environment.coordinator.batches["one"]?.items.first?.state, .waitingWiFi)
        XCTAssertNil(environment.coordinator.batches["one"]?.items.first?.taskID)
        environment.coordinator.resume(key: "one", allowsCellular: true)
        for _ in 0..<50 where environment.coordinator.batches["one"]?.items.first?.taskID == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(environment.coordinator.batches["one"]?.items.first?.taskID)
        environment.coordinator.cancel(key: "one")
        try await Task.sleep(for: .seconds(2))
        XCTAssertNil(environment.cache.cachedURL(for: track.id))
        XCTAssertTrue(environment.coordinator.batches["one"]?.cancelled == true)
    }

    @MainActor func testPlaybackTakesOverTransferAndStreamingCompletionFinishesBatch() async throws {
        try await requireFixture()
        let environment = try await makeEnvironment()
        defer { environment.coordinator.reset(); try? FileManager.default.removeItem(at: environment.root) }
        let track = try song()
        environment.coordinator.start(key: "one", title: "One", tracks: [track], allowsCellular: true)
        for _ in 0..<50 where environment.coordinator.batches["one"]?.items.first?.taskID == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        environment.cache.playingKey = track.id
        await environment.coordinator.givePlaybackPriority(to: track)
        XCTAssertEqual(environment.coordinator.batches["one"]?.items.first?.state, .waitingPlayback)
        XCTAssertNil(environment.coordinator.batches["one"]?.items.first?.taskID)
        let file = environment.root.appendingPathComponent("streamed.wav")
        try UITestAudio.silence().write(to: file)
        _ = try environment.cache.storeDownloadedFile(at: file, key: track.id, mimeType: "audio/wav", protectedKey: track.id)
        for _ in 0..<20 where environment.coordinator.batches["one"]?.isFinished != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(environment.coordinator.batches["one"]?.isFinished == true)
    }

    @MainActor func testPausedBackgroundTransferResumes() async throws {
        try await requireFixture()
        let environment = try await makeEnvironment()
        defer { environment.coordinator.reset(); try? FileManager.default.removeItem(at: environment.root) }
        let track = try song()
        environment.coordinator.start(key: "one", title: "One", tracks: [track], allowsCellular: true)
        for _ in 0..<100 where (environment.coordinator.batches["one"]?.items.first?.progress ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        environment.coordinator.pause(key: "one")
        for _ in 0..<100 where environment.coordinator.batches["one"]?.items.first?.taskID != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(environment.coordinator.batches["one"]?.paused == true)
        XCTAssertNotNil(environment.coordinator.batches["one"]?.items.first?.resumeData)
        environment.coordinator.resume(key: "one")
        for _ in 0..<200 where environment.coordinator.batches["one"]?.isFinished != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(environment.coordinator.batches["one"]?.isFinished == true)
        XCTAssertNotNil(environment.cache.availableCache(for: track))
    }

    private func requireFixture() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18763/health")!)
        request.timeoutInterval = 1
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: String]
            guard payload?["fixture"] == "lemon-cache-tests" else { throw URLError(.badServerResponse) }
        } catch {
            throw XCTSkip("先运行 scripts/cache-fixture-server.py 才执行后台缓存集成测试")
        }
    }

    @MainActor private func makeEnvironment() async throws -> (coordinator: CollectionCacheCoordinator, cache: AudioCache, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try CacheStore(inMemory: true)
        let cache = AudioCache(container: store.container, root: root)
        let api = LemonAPIClient()
        try await api.configure(baseURL: "http://127.0.0.1:18763", token: nil)
        let coordinator = CollectionCacheCoordinator(
            api: api, audioCache: cache, store: store, background: true, monitorNetwork: false,
            sessionIdentifier: "top.btop.music.cache-test.\(UUID())"
        )
        coordinator.configure(account: "fixture")
        return (coordinator, cache, root)
    }

    private func song() throws -> MusicTrack {
        try XCTUnwrap(MusicTrack(json: .object([
            "songId": .string(UUID().uuidString), "source": .string("wy"), "name": .string("Cache fixture"),
        ])))
    }
}
