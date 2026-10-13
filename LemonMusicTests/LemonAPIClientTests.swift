import Foundation
import Testing
import UIKit
@testable import LemonMusic

@Suite(.serialized)
struct LemonAPIClientTests {
    @Test func followsServerTranscodeSettingAndCapsOnlineQuality() async throws {
        let client = try await stubClient()
        let log = RequestLog()
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/settings") == true {
                _ = log.record("settings")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"player.playQuality":"flac","player.smoothStream":"true"}"#.utf8))
            }
            let body = try #require(JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any])
            if body["filePath"] != nil { #expect(body["smooth"] as? Bool == true) }
            else { #expect(body["quality"] as? String == "128k") }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"url":"/api/play/local-smooth?ticket=test"}"#.utf8))
        }
        let settings = try await client.serverPlaybackSettings()
        #expect(settings.smooth)
        let local = try #require(MusicTrack(json: .object(["filePath": .string("/music/song.flac")])))
        _ = try await client.resolvePlayURL(for: local, smooth: settings.smooth)
        let online = try #require(MusicTrack(json: .object(["songId": .string("1"), "source": .string("wy")])))
        _ = try await client.resolvePlayURL(for: online)
        #expect(log.count("settings") == 1)
    }

    @MainActor @Test func coverUsesAuthenticatedProxyWhenCDNRejectsDirectRequest() async throws {
        let client = try await stubClient()
        let log = RequestLog()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let bytes = try #require(image.pngData())
        URLProtocolStub.handler = { request in
            if request.url?.host == "cdn.example.com" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                _ = log.record("cdn")
                return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data())
            }
            #expect(request.url?.path == "/api/v1/play/cover-img")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
            _ = log.record("proxy")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, bytes)
        }
        let track = try #require(MusicTrack(json: .object([
            "source": .string("wy"), "songId": .string("1"), "picUrl": .string("https://cdn.example.com/cover.jpg"),
        ])))
        #expect(try await client.coverData(for: track) == bytes)
        #expect(log.count("cdn") == 1)
        #expect(log.count("proxy") == 1)
    }

    @MainActor @Test func missingCoverIsResolvedAndHTMLIsNeverAcceptedAsImage() async throws {
        let client = try await stubClient()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let bytes = try #require(image.pngData())
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/play/cover") == true {
                return (response, Data(#"{"url":"https://cdn.example.com/found.png"}"#.utf8))
            }
            return (response, request.url?.path == "/found.png" ? bytes : Data("<html>error</html>".utf8))
        }
        let track = try #require(MusicTrack(json: .object(["source": .string("wy"), "songId": .string("1")])))
        #expect(try await client.coverData(for: track) == bytes)
        #expect(await client.remoteCoverData("https://cdn.example.com/error") == nil)
    }

    @Test func followsServerQualityUnlessCellularOverrideIsProvided() async throws {
        let client = try await stubClient()
        let log = RequestLog()
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/settings") == true {
                _ = log.record("settings")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"player.playQuality":"flac"}"#.utf8))
            }
            let body = try #require(JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any])
            let call = log.record("play")
            #expect(body["quality"] as? String == (call == 1 ? "128k" : "flac"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"url":"https://cdn.example.net/music.mp3"}"#.utf8))
        }
        let track = try #require(MusicTrack(json: .object(["source": .string("wy"), "songId": .string("1")])))
        _ = try await client.resolvePlayURL(for: track, quality: "128k")
        #expect(log.count("settings") == 0)
        _ = try await client.resolvePlayURL(for: track)
        _ = try await client.resolvePlayURL(for: track)
        #expect(log.count("settings") == 1)
    }

    @MainActor @Test func playbackStartupTimeoutHasVisibleFailureAndIgnoresLateURL() async throws {
        let client = try await stubClient()
        URLProtocolStub.handler = { request in
            Thread.sleep(forTimeInterval: 0.4)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"url":"https://cdn.example.net/music.mp3"}"#.utf8))
        }
        let store = try CacheStore(inMemory: true)
        let player = PlaybackController(
            api: client, audioCache: AudioCache(container: store.container), artworkStore: ArtworkStore(),
            defaults: UserDefaults(suiteName: "timeout-test.\(UUID())")!, startupTimeout: .milliseconds(100)
        )
        let track = try #require(MusicTrack(json: .object(["filePath": .string("/unique-\(UUID()).mp3")])))
        await player.play(track, in: [track])
        #expect(player.lastError?.contains("超时") == true)
        #expect(!player.isPlaying)
        #expect(!player.isLoadingTrack)
        player.stop()
    }

    @Test func loginUsesV1BearerContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        URLProtocolStub.handler = { request in
            #expect(request.url?.path == "/api/v1/auth/login")
            #expect(request.httpMethod == "POST")
            let body = #"{"token":"jwt","user":{"id":"1","username":"admin","displayName":"Admin","role":"admin"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let client = LemonAPIClient(session: session)
        try await client.configure(baseURL: "https://music.example.com", token: nil)
        let login = try await client.login(username: "admin", password: "secret")
        #expect(login.token == "jwt")
        #expect(login.user.role == "admin")
    }

    @Test func loginFallsBackToLegacyPrefixWhenDeployedV1IsProtected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/v1/auth/login" {
                let body = #"{"error":"未登录或登录已过期","code":"UNAUTHORIZED"}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            #expect(request.url?.path == "/api/auth/login")
            let body = #"{"token":"jwt","user":{"id":"1","username":"admin","displayName":"Admin","role":"admin"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let client = LemonAPIClient(session: session)
        try await client.configure(baseURL: "https://music.example.com", token: nil)
        let login = try await client.login(username: "admin", password: "secret")
        #expect(login.token == "jwt")
        #expect(await client.selectedAPIPrefix() == "/api")
    }

    @Test func lyricsRequestPrefersWordTimedResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        URLProtocolStub.handler = { request in
            #expect(request.url?.path == "/api/v1/play/lyric")
            #expect(request.httpMethod == "POST")
            let body = try request.bodyData()
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["preferWords"] as? Bool == true)
            let response = #"{"ok":true,"lyric":"[00:01.00]Line","ylyric":"[1000,500](0,500,0)Word"}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(response.utf8))
        }

        let track = try #require(MusicTrack(json: .object([
            "filePath": .string("/music/song.mp3"),
            "title": .string("Song"),
            "artist": .string("Artist"),
        ])))
        let client = LemonAPIClient(session: session)
        try await client.configure(baseURL: "https://music.example.com", token: "jwt")

        let value = try await client.lyrics(for: track)
        #expect(value == "[1000,500](0,500,0)Word")
    }

    @Test func collectionDetailsUseProviderIDAndPagination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = LemonAPIClient(session: URLSession(configuration: configuration))
        try await client.configure(baseURL: "https://music.example.com", token: "jwt")
        URLProtocolStub.handler = { request in
            #expect(request.url?.path == "/api/v1/discover/toplist")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "id", value: "3778678")))
            #expect(query.contains(URLQueryItem(name: "source", value: "wy")))
            #expect(query.contains(URLQueryItem(name: "page", value: "2")))
            let body = #"{"ok":true,"data":{"list":[{"id":"1","name":"Song","singer":"Artist"}],"total":150}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let collection = OnlineCollection(kind: .toplist, source: "wy", id: "3778678", title: "榜单")
        let result = try await client.collectionTracks(collection, page: 2)
        #expect(result.total == 150)
        #expect(result.tracks.first?.id == "online:wy:1")
    }

    @MainActor @Test func discoverRefreshUpdatesSuccessfulSectionsAndBypassesFreshCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = LemonAPIClient(session: URLSession(configuration: configuration))
        try await client.configure(baseURL: "https://music.example.com", token: "jwt")
        let log = RequestLog()
        URLProtocolStub.handler = { request in
            let path = request.url!.path
            let count = log.record(path)
            let code: Int
            let body: String
            if path.hasSuffix("/new-songs") {
                code = 200
                body = #"{"data":{"list":[{"songId":"song-"# + String(count) + #"","name":"Song","singer":"Artist"}]}}"#
            } else if path.hasSuffix("/new-albums") {
                code = 200
                body = #"{"data":{"list":[{"id":"album","name":"Album"}]}}"#
            } else {
                code = 500
                body = #"{"error":"排行榜暂不可用"}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let model = try AppModel(inMemory: true, api: client)
        model.selectedSourceID = "wy"
        await model.refreshDiscover(force: true)
        #expect(model.discoverSongs.first?.id == "online:wy:song-1")
        #expect(log.count("/api/v1/discover/new-albums") == 0)
        #expect(model.discoverError?.contains("排行榜") == true)
        #expect(!model.isRefreshingDiscover)
        await model.refreshDiscover(force: true)
        #expect(model.discoverSongs.first?.id == "online:wy:song-2")
        #expect(log.count("/api/v1/discover/new-albums") == 0)
        await model.refreshDiscover()
        #expect(log.count("/api/v1/discover/new-songs") == 2)
        #expect(log.count("/api/v1/discover/toplists") == 2)
    }

    @MainActor @Test func onlinePlaybackSearchesServerLibraryAndCachesMatch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = LemonAPIClient(session: URLSession(configuration: configuration))
        try await client.configure(baseURL: "https://music.example.com", token: "jwt")
        let log = RequestLog()
        URLProtocolStub.handler = { request in
            #expect(request.url?.path == "/api/v1/library/tracks")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "q", value: "夜曲")))
            _ = log.record(request.url!.path)
            let body = #"{"data":[{"filePath":"/music/song.mp3","title":"夜曲","artist":"周杰伦","duration":200}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let model = try AppModel(inMemory: true, api: client)
        let online = try #require(MusicTrack(json: .object([
            "songId": .string("1"), "source": .string("wy"),
            "title": .string("夜曲"), "artist": .string("周杰伦"), "duration": .number(200),
        ])))
        let first = await model.preferredLocalTrack(for: online)
        let repeated = await model.preferredLocalTrack(for: online)
        #expect(first.locator.kind == .local)
        #expect(first.locator.filePath == "/music/song.mp3")
        #expect(repeated.id == first.id)
        #expect(log.count("/api/v1/library/tracks") == 1)
    }

    @MainActor @Test func playlistSearchOnlyRequestsSelectedKindAndReusesFreshCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = LemonAPIClient(session: URLSession(configuration: configuration))
        try await client.configure(baseURL: "https://music.example.com", token: "jwt")
        let log = RequestLog()
        URLProtocolStub.handler = { request in
            #expect(request.url?.path == "/api/v1/search/playlist")
            _ = log.record(request.url!.path)
            let body = #"{"data":{"list":[{"id":"p1","name":"歌单","img":"https://example.com/cover.jpg"}]}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let model = try AppModel(inMemory: true, api: client)
        model.selectedSourceID = "wy"
        await model.searchOnline("Song", kind: .playlists)
        await model.searchOnline("Song", kind: .playlists)
        #expect(model.onlineSearchPlaylists.first?.providerID == "p1")
        #expect(log.count("/api/v1/search/playlist") == 1)
    }

    @MainActor @Test func completeLocalCollectionsFetchAllPagesWithServerFilter() async throws {
        let client = try await stubClient()
        let log = RequestLog()
        URLProtocolStub.handler = { request in
            #expect(request.url?.path == "/api/v1/library/tracks")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "artist", value: "Artist")))
            let count = log.record("pages")
            let body = count == 1
                ? #"{"data":[{"filePath":"/a.mp3","title":"A"}],"total":2}"#
                : #"{"data":[{"filePath":"/b.mp3","title":"B"}],"total":2}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let model = try AppModel(inMemory: true, api: client)
        let tracks = try await model.completeCollection(.local(LocalCollection(kind: .artist, value: "Artist")))
        #expect(tracks.map(\.title) == ["A", "B"])
        #expect(log.count("pages") == 2)
    }

    @MainActor @Test func incompleteOnlinePlaylistCannotBecomeFullCollection() async throws {
        let client = try await stubClient()
        URLProtocolStub.handler = { request in
            let body = #"{"data":{"list":[{"songId":"1","name":"A"}],"trackTotal":2}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let model = try AppModel(inMemory: true, api: client)
        let source = CollectionSource.online(OnlineCollection(kind: .playlist, source: "wy", id: "p", title: "P"))
        await #expect(throws: CollectionError.self) { try await model.completeCollection(source) }
        #expect(model.cachedCompleteCollection(source) == nil)
    }

    @MainActor @Test func favoritePlaylistDeduplicatesAndRetriesFailedSynchronization() async throws {
        let client = try await stubClient()
        let log = RequestLog()
        URLProtocolStub.handler = { request in
            #expect(request.url?.path == "/api/v1/library/user-data")
            let root = try #require(JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any])
            let playlists = try #require(root["playlists"] as? [[String: Any]])
            #expect(playlists.count == 1)
            #expect(playlists[0]["playlistType"] as? String == "imported")
            let count = log.record("save")
            let code = count == 1 ? 500 : 200
            return (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data((code == 200 ? #"{"ok":true}"# : #"{"error":"暂时不可用"}"#).utf8))
        }
        let model = try AppModel(inMemory: true, api: client)
        let source = CollectionSource.online(OnlineCollection(kind: .playlist, source: "wy", id: "123", title: "收藏"))
        model.favoriteCollection(source, tracks: [])
        model.favoriteCollection(source, tracks: [])
        #expect(model.userData.playlists.count == 1)
        await model.retryUserDataSync()
        #expect(model.userDataSyncError != nil)
        #expect(model.isCollectionFavorite(source))
        await model.retryUserDataSync()
        #expect(model.userDataSyncError == nil)
        model.createPlaylist(name: "自建")
        model.unfavoriteCollection(source)
        #expect(model.userData.playlists.count == 1)
        #expect(model.userData.playlists.first?.name == "自建")
    }

    @MainActor @Test func nasBatchesRetryOnlyUnsubmittedChunk() async throws {
        let client = try await stubClient()
        let log = RequestLog()
        URLProtocolStub.handler = { request in
            if request.url?.path.hasSuffix("/download/list") == true {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            }
            #expect(request.url?.path == "/api/v1/download/add")
            let root = try #require(JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any])
            let tasks = try #require(root["tasks"] as? [[String: Any]])
            let call = log.record("add")
            #expect(tasks.count <= 50)
            #expect(tasks.first?["quality"] as? String == "flac")
            let first = tasks.first?["songId"] as? String
            if call == 1 { #expect(first == "0") }
            if call == 2 || call == 3 { #expect(first == "50") }
            let code = call == 2 ? 500 : 200
            let body = code == 500 ? #"{"error":"temporary"}"# : #"{"ok":true,"ids":["task-"# + String(call) + #""],"skipped":0}"#
            return (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let coordinator = NASDownloadCoordinator(api: client, store: try CacheStore(inMemory: true))
        coordinator.configure(account: "test")
        let tracks = try (0..<51).map { index in
            try #require(MusicTrack(json: .object(["songId": .string("\(index)"), "source": .string("wy"), "name": .string("Song")])))
        }
        coordinator.start(key: "p", title: "P", tracks: tracks, quality: .flac)
        for _ in 0..<100 where coordinator.submitting.contains("p") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(coordinator.batches["p"]?.cursor == 50)
        #expect(coordinator.batches["p"]?.error != nil)
        coordinator.retry(key: "p")
        for _ in 0..<100 where coordinator.submitting.contains("p") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(coordinator.batches["p"]?.submissionComplete == true)
        #expect(log.count("add") == 3)
        coordinator.reset()
    }

    @Test func audioDownloadRequestDoesNotLeakBearerToCDN() async throws {
        let client = try await stubClient()
        URLProtocolStub.handler = { request in
            let body = #"{"url":"https://cdn.example.net/audio.mp3"}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let track = try #require(MusicTrack(json: .object(["songId": .string("1"), "source": .string("wy")])))
        let request = try await client.audioDownloadRequest(for: track)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    private func stubClient() async throws -> LemonAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = LemonAPIClient(session: URLSession(configuration: configuration))
        try await client.configure(baseURL: "https://music.example.com", token: "jwt")
        return client
    }
}

private nonisolated final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        counts[path, default: 0] += 1
        return counts[path, default: 0]
    }

    func count(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path, default: 0]
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private extension URLRequest {
    func bodyData() throws -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { throw URLError(.cannotDecodeContentData) }
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
