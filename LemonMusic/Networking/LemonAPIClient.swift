// Derived from Cassette, licensed under MPL-2.0.

import Foundation

actor LemonAPIClient {
    enum APIError: LocalizedError, Sendable {
        case invalidServer
        case unauthorized
        case server(status: Int, message: String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidServer: "服务器地址无效"
            case .unauthorized: "登录已失效，请重新登录"
            case .server(_, let message): message
            case .invalidResponse: "服务器响应格式不正确"
            }
        }
    }

    private let session: URLSession
    private var baseURL: URL?
    private var token: String?
    private var apiPrefix = "/api/v1"

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func configure(baseURL: String, token: String?, apiPrefix: String? = nil) throws {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil else { throw APIError.invalidServer }
        components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = components.url else { throw APIError.invalidServer }
        self.baseURL = url
        self.token = token
        if let apiPrefix, ["/api", "/api/v1"].contains(apiPrefix) { self.apiPrefix = apiPrefix }
    }

    func updateToken(_ token: String?) { self.token = token }
    func selectedAPIPrefix() -> String { apiPrefix }

    func login(username: String, password: String) async throws -> LoginSession {
        let body: JSONValue = .object([
            "username": .string(username),
            "password": .string(password),
            "remember": .bool(true),
        ])
        let root: JSONValue
        do {
            root = try await request("/auth/login", method: "POST", body: body, requiresAuth: false)
        } catch APIError.unauthorized where apiPrefix == "/api/v1" {
            apiPrefix = "/api"
            root = try await request("/auth/login", method: "POST", body: body, requiresAuth: false)
        }
        guard let object = root.object,
              let token = object["token"]?.string,
              let userObject = object["user"]?.object else { throw APIError.invalidResponse }
        let user = SessionUser(
            id: userObject.firstString("id") ?? username,
            username: userObject.firstString("username") ?? username,
            displayName: userObject.firstString("displayName") ?? username,
            role: userObject.firstString("role") ?? "user"
        )
        self.token = token
        return LoginSession(token: token, user: user)
    }

    func currentUser() async throws -> SessionUser {
        let root: JSONValue
        do {
            root = try await request("/auth/me")
        } catch APIError.unauthorized where apiPrefix == "/api/v1" {
            apiPrefix = "/api"
            root = try await request("/auth/me")
        }
        let object = root["user"]?.object ?? root["data"]?["user"]?.object ?? root["data"]?.object ?? root.object
        guard let object else { throw APIError.invalidResponse }
        return SessionUser(
            id: object.firstString("id") ?? object.firstString("username") ?? "user",
            username: object.firstString("username") ?? "user",
            displayName: object.firstString("displayName") ?? object.firstString("username") ?? "用户",
            role: object.firstString("role") ?? "user"
        )
    }

    func logout() async { _ = try? await request("/auth/logout", method: "POST") }

    func tracks(page: Int = 1, limit: Int = 200, query: String? = nil, sort: String = "mtime") async throws -> [MusicTrack] {
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: sort),
        ]
        if let query, !query.isEmpty { queryItems.append(URLQueryItem(name: "q", value: query)) }
        let root = try await request("/library/tracks", query: queryItems)
        return extractArray(root).compactMap { MusicTrack(json: $0) }
    }

    func albums(page: Int = 1, query: String? = nil) async throws -> [MusicAlbum] {
        var items = [URLQueryItem(name: "page", value: String(page))]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        let values = extractArray(try await request("/library/albums", query: items))
        return values.compactMap { MusicAlbum(json: $0) }
    }

    func artists(page: Int = 1, query: String? = nil) async throws -> [MusicArtist] {
        var items = [URLQueryItem(name: "page", value: String(page))]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        let values = extractArray(try await request("/library/artists", query: items))
        return values.compactMap { MusicArtist(json: $0) }
    }

    func genres() async throws -> [String] {
        extractArray(try await request("/library/genres")).compactMap { value in
            value.string ?? value["name"]?.string ?? value["genre"]?.string
        }
    }

    func sources() async throws -> [MusicSource] {
        let root = try await request("/search/sources")
        guard let object = root["sources"]?.object ?? root["data"]?["sources"]?.object else { return [] }
        return object.map {
            MusicSource(id: $0.key, name: $0.value.string ?? $0.value["name"]?.string ?? $0.key)
        }.sorted { $0.name < $1.name }
    }

    func searchTracks(keyword: String, source: String, page: Int = 1) async throws -> [MusicTrack] {
        let root = try await request("/search", query: [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: "40"),
        ], timeout: 30)
        return extractArray(root).compactMap { MusicTrack(json: $0, defaultSource: source) }
    }

    func searchAlbums(keyword: String, source: String, page: Int = 1) async throws -> [MusicAlbum] {
        let root = try await request("/search/album", query: [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: "30"),
        ], timeout: 30)
        return extractArray(root).compactMap { MusicAlbum(json: $0, defaultSource: source) }
    }

    func newSongs(source: String, region: String = "") async throws -> [MusicTrack] {
        let root = try await request("/discover/new-songs", query: [
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "region", value: region),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "limit", value: "30"),
        ], timeout: 55)
        return extractArray(root).compactMap { MusicTrack(json: $0, defaultSource: source) }
    }

    func newAlbums(source: String, region: String = "") async throws -> [MusicAlbum] {
        let root = try await request("/discover/new-albums", query: [
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "region", value: region),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "limit", value: "20"),
        ], timeout: 55)
        return extractArray(root).compactMap { MusicAlbum(json: $0, defaultSource: source) }
    }

    func toplists(source: String) async throws -> [MusicPlaylist] {
        let root = try await request("/discover/toplists", query: [URLQueryItem(name: "source", value: source)], timeout: 55)
        return extractArray(root).compactMap { MusicPlaylist(json: $0, defaultSource: source) }
    }

    func userData() async throws -> LibraryUserData {
        let root = try await request("/library/user-data")
        let data = root["data"] ?? root
        guard let object = data.object else { return .empty }
        let playlists = (object["playlists"]?.array ?? []).compactMap { MusicPlaylist(json: $0) }
        let favorites = (object["favorites"]?.array ?? []).compactMap { MusicTrack(json: $0) }
        let recentPlays = (object["recentPlays"]?.array ?? []).compactMap { MusicTrack(json: $0) }
        return LibraryUserData(playlists: playlists, favorites: favorites, recentPlays: recentPlays, revision: object["revision"]?.int ?? 0)
    }

    func saveUserData(_ data: LibraryUserData) async throws {
        _ = try await request("/library/user-data", method: "PUT", body: .object([
            "playlists": .array(data.playlists.map(\.json)),
            "favorites": .array(data.favorites.map(\.snapshotJSON)),
            "recentPlays": .array(data.recentPlays.map(\.snapshotJSON)),
            "revision": .number(Double(data.revision)),
        ]))
    }

    func resolvePlayURL(for track: MusicTrack, refresh: Bool = false) async throws -> URL {
        var body: [String: JSONValue] = ["refresh": .bool(refresh)]
        switch track.locator.kind {
        case .local:
            if let trackID = track.locator.trackID { body["trackId"] = .string(trackID) }
            else if let path = track.locator.filePath { body["filePath"] = .string(path) }
        case .online:
            if let songID = track.locator.songID { body["songId"] = .string(songID) }
            if let source = track.locator.source { body["source"] = .string(source) }
            body["quality"] = .string("320k")
            for (key, value) in track.locator.identifiers { body[key] = .string(value) }
        }
        let root = try await request("/play/url", method: "POST", body: .object(body), timeout: 30)
        guard let rawURL = root["url"]?.string ?? root["data"]?["url"]?.string else { throw APIError.invalidResponse }
        return try absoluteURL(rawURL)
    }

    func lyrics(for track: MusicTrack) async throws -> String {
        var body = track.snapshotJSON.object ?? [:]
        if let source = track.locator.source { body["source"] = .string(source) }
        body["preferWords"] = .bool(true)
        let root = try await request("/play/lyric", method: "POST", body: .object(body), timeout: 30)
        let data = root["data"] ?? root
        let wordTimed = data["ylyric"]?.string ?? ""
        return wordTimed.isEmpty ? (data["lyric"]?.string ?? "") : wordTimed
    }

    func coverData(for track: MusicTrack) async throws -> Data? {
        if let direct = track.artworkURL, let url = URL(string: direct), url.scheme != nil {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        if let path = track.locator.filePath {
            return try await data(path: "/tag/cover", query: [URLQueryItem(name: "path", value: path)])
        }
        return nil
    }

    func webSocketURL() throws -> URL {
        guard let baseURL else { throw APIError.invalidServer }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/ws"
        components?.queryItems = token.map { [URLQueryItem(name: "token", value: $0)] }
        guard let url = components?.url else { throw APIError.invalidServer }
        return url
    }

    private func request(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: JSONValue? = nil,
        requiresAuth: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> JSONValue {
        let request = try makeRequest(path, method: method, query: query, body: body, requiresAuth: requiresAuth, timeout: timeout)
        let attempts = method == "GET" ? 2 : 1
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
                if http.statusCode == 401 { throw APIError.unauthorized }
                guard (200..<300).contains(http.statusCode) else {
                    let message = json["error"]?.string ?? "请求失败（\(http.statusCode)）"
                    throw APIError.server(status: http.statusCode, message: message)
                }
                return json
            } catch is CancellationError { throw CancellationError() }
            catch let error as APIError { throw error }
            catch {
                lastError = error
                guard attempt + 1 < attempts else { break }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        throw lastError ?? APIError.invalidResponse
    }

    private func data(path: String, query: [URLQueryItem]) async throws -> Data? {
        let request = try makeRequest(path, method: "GET", query: query, body: nil, requiresAuth: true, timeout: 30)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw APIError.server(status: http.statusCode, message: "资源加载失败") }
        return data
    }

    private func makeRequest(
        _ path: String,
        method: String,
        query: [URLQueryItem],
        body: JSONValue?,
        requiresAuth: Bool,
        timeout: TimeInterval?
    ) throws -> URLRequest {
        guard let baseURL else { throw APIError.invalidServer }
        var url = baseURL
        for component in apiPrefix.split(separator: "/") { url.appendPathComponent(String(component)) }
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let finalURL = components?.url else { throw APIError.invalidServer }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if requiresAuth, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func absoluteURL(_ raw: String) throws -> URL {
        if let url = URL(string: raw), url.scheme != nil { return url }
        guard let baseURL, let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL else { throw APIError.invalidResponse }
        return url
    }

    private func extractArray(_ root: JSONValue) -> [JSONValue] {
        if let array = root.array { return array }
        if let data = root["data"] {
            if let array = data.array { return array }
            if let object = data.object {
                for key in ["list", "items", "songs", "tracks", "albums", "artists", "playlists", "data"] {
                    if let array = object[key]?.array { return array }
                }
            }
        }
        if let object = root.object {
            for key in ["list", "items", "songs", "tracks", "albums", "artists", "playlists"] {
                if let array = object[key]?.array { return array }
            }
        }
        return []
    }
}
