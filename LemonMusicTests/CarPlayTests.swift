import CarPlay
import Foundation
import MediaPlayer
import Testing
@testable import LemonMusic

@Suite(.serialized)
struct CarPlayTests {
    @Test func paginationReservesControlsAndCoversEveryOccurrence() {
        for maximum in [5, 20, 100, 500] {
            let first = CarPlayPagination(count: 603, page: 0, maximumItems: maximum)
            var indices: [Int] = []
            for page in 0..<first.pageCount {
                let slice = CarPlayPagination(count: 603, page: page, maximumItems: maximum)
                #expect(slice.range.count + 4 <= maximum)
                #expect(slice.hasPrevious == (page > 0))
                #expect(slice.hasNext == (page + 1 < first.pageCount))
                indices.append(contentsOf: slice.range)
            }
            #expect(indices == Array(0..<603))
        }
        #expect(CarPlayPagination(count: 0, page: 9, maximumItems: 20).range.isEmpty)
        #expect(CarPlayPagination(count: 4, page: -1, maximumItems: 20).page == 0)
    }

    @Test func selectsDuplicateQueueOccurrencesWithoutRebuildingQueue() throws {
        let songs = try tracks(2)
        var queue = PlaybackQueue()
        queue.replace(with: [songs[0], songs[1], songs[0]], selectingAt: 2)
        #expect(queue.index == 2)
        let occurrence = try #require(queue.current?.id)
        queue.setMode(.shuffled)
        #expect(queue.current?.id == occurrence)
        queue.setMode(.sequential)
        #expect(queue.index == 2)
        let first = queue.ordered[0].id
        let selectedFirst = queue.select(entryID: first)
        #expect(selectedFirst)
        #expect(queue.index == 0)
        let selectedOccurrence = queue.select(entryID: occurrence)
        #expect(selectedOccurrence)
        #expect(queue.index == 2)
        let selectedMissing = queue.select(entryID: UUID())
        #expect(!selectedMissing)
        queue.advance(natural: true)
        #expect(queue.index == 0)
    }

    @MainActor @Test func simultaneousSceneBootstrapRestoresOnlyOneSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let counter = Counter()
        CarPlayProtocol.handler = { request in
            counter.record(request.url!.path)
            if request.url!.path.hasSuffix("/auth/me") { Thread.sleep(forTimeInterval: 0.05) }
            return try response(request)
        }
        async let car: Void = fixture.model.bootstrap(includeDiscovery: false)
        try await Task.sleep(for: .milliseconds(20))
        async let phone: Void = fixture.model.bootstrap()
        _ = await (phone, car)
        await fixture.model.bootstrap()
        #expect(fixture.model.sessionState == .ready)
        #expect(counter.count("/api/v1/auth/me") == 1)
        #expect(counter.count("/api/v1/library/tracks") == 1)
        #expect(counter.count("/api/v1/discover/new-songs") == 0)
        #expect(counter.count("/api/v1/discover/toplists") == 0)
        fixture.model.webSocket.stop()
    }

    @MainActor @Test func expiredSessionShowsLoginInsteadOfCachedPrivateLists() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.model.cacheStore.save(try tracks(2), for: "library.tracks")
        CarPlayProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        await fixture.model.bootstrap()
        let presenter = TestInterface()
        let coordinator = CarPlayCoordinator(model: fixture.model)
        coordinator.connect(to: presenter)
        defer { coordinator.disconnect() }
        #expect(fixture.model.sessionState == .signedOut)
        let list = try #require(presenter.templates.first as? CPListTemplate)
        #expect(list.itemCount == 0)
        #expect(list.emptyViewTitleVariants.contains("请先登录"))
    }

    @MainActor @Test func offlineBootstrapKeepsFavoritesAndLibraryPagesAreCached() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let songs = try tracks(2)
        fixture.model.cacheStore.save(LibraryUserData(playlists: [], favorites: songs, recentPlays: [], revision: 0), for: "library.userData")
        CarPlayProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await fixture.model.bootstrap()
        #expect(fixture.model.sessionState == .offline)
        #expect(fixture.model.userData.favorites.count == 2)
        let counter = Counter()
        CarPlayProtocol.handler = { request in
            counter.record(request.url!.path)
            return try response(request, songs: songs)
        }
        let first = try await fixture.model.carPlayLibraryPage(2)
        let second = try await fixture.model.carPlayLibraryPage(2)
        #expect(first == songs)
        #expect(second == songs)
        #expect(counter.count("/api/v1/library/tracks") == 1)
        let presenter = TestInterface()
        let coordinator = CarPlayCoordinator(model: fixture.model)
        coordinator.connect(to: presenter)
        defer { coordinator.disconnect() }
        let tabs = try #require(presenter.templates.first as? CPTabBarTemplate)
        #expect(tabs.templates.count == 4)
        let favorites = try #require(tabs.templates[1] as? CPListTemplate)
        #expect(favorites.itemCount == 3)
    }

    @MainActor @Test func playlistSelectionQueuesAllSongsAndDisconnectDoesNotStopPlayback() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let songs = try tracks(205)
        let playlist = MusicPlaylist(id: "test-list", name: "Test Playlist", tracks: songs)
        CarPlayProtocol.handler = { request in try response(request, playlist: playlist) }
        await fixture.model.bootstrap()
        for song in [songs[0], songs[100]] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try UITestAudio.silence().write(to: file)
            _ = try fixture.model.audioCache.storeDownloadedFile(at: file, key: song.id, mimeType: "audio/wav", protectedKey: nil)
        }
        let presenter = TestInterface()
        let coordinator = CarPlayCoordinator(model: fixture.model)
        coordinator.connect(to: presenter)
        defer { coordinator.disconnect() }
        let tabs = try #require(presenter.templates.first as? CPTabBarTemplate)
        let playlists = try #require(tabs.templates[2] as? CPListTemplate)
        try await tap(try #require(playlists.sections.first?.items.first as? CPListItem))
        let details = try #require(presenter.templates.last as? CPListTemplate)
        try await tap(try #require(details.sections.first?.items.first as? CPListItem))
        #expect(fixture.model.playback.queue.count == 205)
        #expect(fixture.model.playback.currentTrack?.id == songs[0].id)
        #expect(presenter.templates.last === CPNowPlayingTemplate.shared)
        let selected = fixture.model.playback.currentEntryID
        coordinator.nowPlayingTemplateUpNextButtonTapped(CPNowPlayingTemplate.shared)
        let queue = try #require(presenter.templates.last as? CPListTemplate)
        let next = try #require(queue.sections.first?.items.last as? CPListItem)
        #expect(next.text == "下一页")
        try await tap(next)
        try await tap(try #require(queue.sections.first?.items.first as? CPListItem))
        #expect(fixture.model.playback.currentIndex == 100)
        #expect(fixture.model.playback.queue.count == 205)
        coordinator.disconnect()
        #expect(!coordinator.isConnected)
        #expect(fixture.model.playback.currentEntryID != selected)
        #expect(fixture.model.playback.isPlaying)
        #expect(fixture.model.playback.queue.count == 205)
    }

    @MainActor @Test func logoutClearsCarPlayAndStaleSelectionIsCompleted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let playlist = MusicPlaylist(id: "list", name: "Private", tracks: try tracks(1))
        CarPlayProtocol.handler = { request in try response(request, playlist: playlist) }
        await fixture.model.bootstrap()
        let presenter = TestInterface()
        let coordinator = CarPlayCoordinator(model: fixture.model)
        coordinator.connect(to: presenter)
        defer { coordinator.disconnect() }
        let tabs = try #require(presenter.templates.first as? CPTabBarTemplate)
        let list = try #require(tabs.templates[2] as? CPListTemplate)
        let staleItem = try #require(list.sections.first?.items.first as? CPListItem)
        await fixture.model.logout()
        for _ in 0..<20 { await Task.yield() }
        let login = try #require(presenter.templates.first as? CPListTemplate)
        #expect(login.itemCount == 0)
        try await tap(staleItem)
        #expect(presenter.templates.count == 1)
        #expect(fixture.model.playback.currentTrack == nil)
        #expect(fixture.model.cachedCarPlayLibraryPage(2) == nil)
    }

    @MainActor @Test func modeControlsReflectExistingMutuallyExclusiveModes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let player = fixture.model.playback
        player.setMode(.shuffled)
        #expect(MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType == .items)
        player.setMode(.repeatOne)
        #expect(MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType == .off)
        #expect(MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType == .one)
        player.setMode(.sequential)
        #expect(MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType == .all)
    }

    @MainActor @Test func nowPlayingRateMatchesEngineAfterStartingAndSkippingCachedSongs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let songs = try tracks(2)
        for song in songs {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try UITestAudio.silence().write(to: file)
            _ = try fixture.model.audioCache.storeDownloadedFile(at: file, key: song.id, mimeType: "audio/wav", protectedKey: nil)
        }
        await fixture.model.playback.play(at: 0, in: songs)
        for turn in 0..<2 {
            if turn == 1 { await fixture.model.playback.next() }
            for _ in 0..<60 {
                if fixture.model.playback.isPlaying, fixture.model.playback.position > 0,
                   (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 1 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(fixture.model.playback.isPlaying)
            #expect(MPNowPlayingInfoCenter.default().playbackState == .playing)
            #expect((MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 1)
            #expect(fixture.model.playback.currentIndex == turn)
        }
        fixture.model.playback.pause()
        #expect(MPNowPlayingInfoCenter.default().playbackState == .paused)
        #expect((MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0)
        fixture.model.playback.handleInterruptionBegan()
        #expect(MPNowPlayingInfoCenter.default().playbackState == .interrupted)
        fixture.model.playback.stop()
        #expect(MPNowPlayingInfoCenter.default().playbackState == .stopped)
    }

    @MainActor @Test func disconnectCancelsLibraryLoadingAndFinishesSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let songs = try tracks(200)
        let stops = Counter()
        CarPlayProtocol.onStop = { stops.record("stop") }
        defer { CarPlayProtocol.onStop = nil }
        CarPlayProtocol.handler = { request in
            if request.url?.query?.contains("page=2") == true { Thread.sleep(forTimeInterval: 0.4) }
            return try response(request, songs: songs)
        }
        await fixture.model.bootstrap(includeDiscovery: false)
        let presenter = TestInterface()
        let coordinator = CarPlayCoordinator(model: fixture.model)
        coordinator.connect(to: presenter)
        defer { coordinator.disconnect() }
        let tabs = try #require(presenter.templates.first as? CPTabBarTemplate)
        let library = try #require(tabs.templates[3] as? CPListTemplate)
        let next = try #require(library.sections.first?.items.last as? CPListItem)
        #expect(next.text == "下一页")
        try await tap(next)
        let more = try #require(library.sections.first?.items.last as? CPListItem)
        #expect(more.text == "更多歌曲")
        let selection = Task { try await tap(more) }
        try await Task.sleep(for: .milliseconds(50))
        coordinator.disconnect()
        try await selection.value
        #expect(!coordinator.isConnected)
        #expect(stops.count("stop") > 0)
        #expect(fixture.model.cachedCarPlayLibraryPage(2) == nil)
    }

    @MainActor private func tap(_ item: CPListItem) async throws {
        let handler = try #require(item.handler)
        await withCheckedContinuation { continuation in
            handler(item) { continuation.resume() }
        }
    }
}

@MainActor
private struct Fixture {
    let model: AppModel
    let defaults: UserDefaults
    let keychain: KeychainStore
    let name = "lemon.carplay.tests.\(UUID())"

    init() throws {
        defaults = UserDefaults(suiteName: name)!
        keychain = KeychainStore(service: name)
        try keychain.set("test-token", for: "session-token")
        defaults.set(try JSONEncoder().encode(ServerProfile(baseURL: "https://carplay.invalid", username: "test", user: nil, apiPrefix: "/api/v1")), forKey: "lemon.serverProfile")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CarPlayProtocol.self]
        model = try AppModel(inMemory: true, api: LemonAPIClient(session: URLSession(configuration: configuration)), defaults: defaults, keychain: keychain)
    }

    func cleanUp() {
        model.playback.stop()
        model.webSocket.stop()
        model.audioCache.clear()
        model.collectionCache.reset()
        model.nasDownloads.reset()
        keychain.delete("session-token")
        defaults.removePersistentDomain(forName: name)
    }
}

@MainActor
private final class TestInterface: CarPlayPresenting {
    var templates: [CPTemplate] = []
    var imageScale: CGFloat { 2 }
    var alert: CPAlertTemplate?
    func setRoot(_ template: CPTemplate) { templates = [template] }
    func push(_ template: CPTemplate) { templates.append(template) }
    func pop(to template: CPTemplate) {
        if let index = templates.firstIndex(where: { $0 === template }) { templates = Array(templates.prefix(index + 1)) }
    }
    func present(_ alert: CPAlertTemplate) { self.alert = alert }
    func dismissAlert() { alert = nil }
}

private func tracks(_ count: Int) throws -> [LemonMusic.MusicTrack] {
    try (0..<count).map { index in
        let decoded = LemonMusic.MusicTrack(json: .object([
            "filePath": .string("/test/\(index).wav"), "title": .string("Song \(index)"),
            "artist": .string("Artist"), "duration": .number(20),
        ]))
        return try #require(decoded)
    }
}

private func response(_ request: URLRequest, songs: [LemonMusic.MusicTrack] = [], playlist: MusicPlaylist? = nil) throws -> (HTTPURLResponse, Data) {
    let json: JSONValue
    if request.url!.path.hasSuffix("/auth/me") {
        json = .object(["id": .string("test"), "username": .string("test")])
    } else if request.url!.path.hasSuffix("/library/tracks") {
        json = .array(songs.map(\.snapshotJSON))
    } else if request.url!.path.hasSuffix("/library/user-data") {
        json = .object(["playlists": .array(playlist.map { [$0.json] } ?? [])])
    } else { json = .object([:]) }
    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(json))
}

private final class CarPlayProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { Self.onStop?() }
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func record(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key, default: 0] += 1
    }
    func count(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values[key, default: 0]
    }
}
