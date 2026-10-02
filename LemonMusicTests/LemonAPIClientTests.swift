import Foundation
import Testing
@testable import LemonMusic

@Suite(.serialized)
struct LemonAPIClientTests {
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
        #expect(model.discoverAlbums.count == 1)
        #expect(model.discoverError?.contains("排行榜") == true)
        #expect(!model.isRefreshingDiscover)
        await model.refreshDiscover(force: true)
        #expect(model.discoverSongs.first?.id == "online:wy:song-2")
        #expect(model.discoverAlbums.count == 1)
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
