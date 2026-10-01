// Derived from Cassette, licensed under MPL-2.0.

import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    enum SessionState { case loading, signedOut, ready, offline }

    private(set) var sessionState: SessionState = .loading
    private(set) var profile: ServerProfile?
    private(set) var tracks: [MusicTrack] = []
    private(set) var albums: [MusicAlbum] = []
    private(set) var artists: [MusicArtist] = []
    private(set) var genres: [String] = []
    private(set) var sources: [MusicSource] = []
    private(set) var userData: LibraryUserData = .empty
    private(set) var discoverSongs: [MusicTrack] = []
    private(set) var discoverAlbums: [MusicAlbum] = []
    private(set) var toplists: [MusicPlaylist] = []
    private(set) var onlineSearchResults: [MusicTrack] = []
    private(set) var onlineSearchAlbums: [MusicAlbum] = []
    private(set) var isRefreshing = false
    private(set) var isSearching = false
    var errorMessage: String?

    var selectedSourceID: String {
        didSet { UserDefaults.standard.set(selectedSourceID, forKey: "lemon.selectedSource") }
    }

    let api = LemonAPIClient()
    let cacheStore: CacheStore
    let audioCache: AudioCache
    let artworkStore = ArtworkStore()
    let playback: PlaybackController
    let webSocket = LemonWebSocket()

    private let keychain = KeychainStore()
    private let profileKey = "lemon.serverProfile"
    private let tokenKey = "session-token"
    private var saveUserDataTask: Task<Void, Never>?

    init(inMemory: Bool = false) throws {
        cacheStore = try CacheStore(inMemory: inMemory)
        audioCache = AudioCache(container: cacheStore.container)
        playback = PlaybackController(api: api, audioCache: audioCache, artworkStore: artworkStore)
        selectedSourceID = UserDefaults.standard.string(forKey: "lemon.selectedSource") ?? "kw"
        webSocket.onEvent = { [weak self] type in self?.handleWebSocketEvent(type) }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingReset") {
            keychain.delete(tokenKey)
            UserDefaults.standard.removeObject(forKey: profileKey)
            cacheStore.clearAll()
            audioCache.clear()
            artworkStore.clear()
        }
    }

    var favoriteIDs: Set<String> { Set(userData.favorites.map(\.id)) }
    var recentTracks: [MusicTrack] { userData.recentPlays }
    var recentlyAdded: [MusicTrack] {
        tracks.sorted { ($0.modifiedAt ?? 0) > ($1.modifiedAt ?? 0) }.prefix(30).map { $0 }
    }

    func bootstrap() async {
        loadCachedData()
        guard let profile = loadProfile(), let token = keychain.get(tokenKey) else {
            sessionState = .signedOut
            return
        }
        self.profile = profile
        do {
            try await api.configure(baseURL: profile.baseURL, token: token, apiPrefix: profile.apiPrefix)
            sessionState = tracks.isEmpty ? .loading : .ready
            let user = try await api.currentUser()
            self.profile?.user = user
            self.profile?.apiPrefix = await api.selectedAPIPrefix()
            saveProfile()
            sessionState = .ready
            connectWebSocket()
            await refreshAll(force: false)
        } catch LemonAPIClient.APIError.unauthorized {
            keychain.delete(tokenKey)
            sessionState = .signedOut
        } catch {
            sessionState = tracks.isEmpty ? .signedOut : .offline
            errorMessage = tracks.isEmpty ? "无法连接服务器，请检查地址和网络" : nil
        }
    }

    func login(baseURL: String, username: String, password: String) async throws {
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        try await api.configure(baseURL: normalized, token: nil)
        let session = try await api.login(username: username, password: password)
        try keychain.set(session.token, for: tokenKey)
        profile = ServerProfile(
            baseURL: normalized,
            username: username,
            user: session.user,
            apiPrefix: await api.selectedAPIPrefix()
        )
        saveProfile()
        sessionState = .ready
        connectWebSocket()
        await refreshAll(force: true)
    }

    func logout() async {
        await api.logout()
        webSocket.stop()
        keychain.delete(tokenKey)
        profile = nil
        UserDefaults.standard.removeObject(forKey: profileKey)
        clearAllCachedData()
        sessionState = .signedOut
    }

    func changeServer() async {
        await logout()
    }

    func refreshAll(force: Bool = true) async {
        guard sessionState != .signedOut else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let loadedTracks = api.tracks()
            async let loadedAlbums = api.albums()
            async let loadedArtists = api.artists()
            async let loadedGenres = api.genres()
            async let loadedSources = api.sources()
            async let loadedUserData = api.userData()
            let values = try await (loadedTracks, loadedAlbums, loadedArtists, loadedGenres, loadedSources, loadedUserData)
            tracks = values.0
            albums = values.1
            artists = values.2
            genres = values.3
            sources = values.4
            userData = values.5
            if !sources.contains(where: { $0.id == selectedSourceID }), let first = sources.first {
                selectedSourceID = first.id
            }
            cacheStore.save(tracks, for: "library.tracks", ttl: 10 * 60)
            cacheStore.save(albums, for: "library.albums", ttl: 10 * 60)
            cacheStore.save(artists, for: "library.artists", ttl: 10 * 60)
            cacheStore.save(genres, for: "library.genres", ttl: 10 * 60)
            cacheStore.save(sources, for: "search.sources", ttl: 24 * 60 * 60)
            cacheStore.save(userData, for: "library.userData")
            sessionState = .ready
            await refreshDiscover(force: force)
        } catch LemonAPIClient.APIError.unauthorized {
            keychain.delete(tokenKey)
            sessionState = .signedOut
        } catch {
            sessionState = tracks.isEmpty ? .offline : sessionState
            errorMessage = error.localizedDescription
        }
    }

    func refreshDiscover(force: Bool = false) async {
        guard !selectedSourceID.isEmpty else { return }
        let cachePrefix = "discover.\(selectedSourceID)"
        if !force, cacheStore.isFresh(cachePrefix + ".songs") {
            loadDiscoverCache(prefix: cachePrefix)
            return
        }
        do {
            async let songs = api.newSongs(source: selectedSourceID)
            async let albums = api.newAlbums(source: selectedSourceID)
            async let lists = api.toplists(source: selectedSourceID)
            let result = try await (songs, albums, lists)
            discoverSongs = result.0
            discoverAlbums = result.1
            toplists = result.2
            cacheStore.save(discoverSongs, for: cachePrefix + ".songs", ttl: 30 * 60)
            cacheStore.save(discoverAlbums, for: cachePrefix + ".albums", ttl: 30 * 60)
            cacheStore.save(toplists, for: cachePrefix + ".toplists", ttl: 30 * 60)
        } catch {
            loadDiscoverCache(prefix: cachePrefix)
            errorMessage = error.localizedDescription
        }
    }

    func selectSource(_ id: String) async {
        selectedSourceID = id
        loadDiscoverCache(prefix: "discover.\(id)")
        await refreshDiscover(force: false)
    }

    func searchOnline(_ query: String) async {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            onlineSearchResults = []
            onlineSearchAlbums = []
            return
        }
        let cacheKey = "search.\(selectedSourceID).\(value.lowercased())"
        if let cached: [MusicTrack] = cacheStore.value([MusicTrack].self, for: cacheKey, allowExpired: false) {
            onlineSearchResults = cached
        }
        isSearching = true
        defer { isSearching = false }
        do {
            async let tracks = api.searchTracks(keyword: value, source: selectedSourceID)
            async let albums = api.searchAlbums(keyword: value, source: selectedSourceID)
            let result = try await (tracks, albums)
            onlineSearchResults = result.0
            onlineSearchAlbums = result.1
            cacheStore.save(result.0, for: cacheKey, ttl: 15 * 60)
            cacheStore.save(result.1, for: cacheKey + ".albums", ttl: 15 * 60)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func localSearch(_ query: String) -> [MusicTrack] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(value)
                || $0.artist.localizedCaseInsensitiveContains(value)
                || $0.album.localizedCaseInsensitiveContains(value)
        }
    }

    func play(_ track: MusicTrack, in queue: [MusicTrack]? = nil) async {
        recordRecentPlay(track)
        await playback.play(track, in: queue)
    }

    func toggleFavorite(_ track: MusicTrack) {
        if let index = userData.favorites.firstIndex(where: { $0.id == track.id }) {
            userData.favorites.remove(at: index)
        } else {
            userData.favorites.insert(track, at: 0)
        }
        userData.revision += 1
        persistUserData()
    }

    func createPlaylist(name: String) {
        userData.playlists.insert(MusicPlaylist(name: name), at: 0)
        userData.revision += 1
        persistUserData()
    }

    func add(_ track: MusicTrack, to playlistID: String) {
        guard let index = userData.playlists.firstIndex(where: { $0.id == playlistID }),
              !userData.playlists[index].tracks.contains(track) else { return }
        userData.playlists[index].tracks.append(track)
        userData.revision += 1
        persistUserData()
    }

    func lyrics(for track: MusicTrack) async -> String {
        let key = "lyrics.v2.\(track.id)"
        if let cached: String = cacheStore.value(String.self, for: key, allowExpired: false) { return cached }
        let value = (try? await api.lyrics(for: track)) ?? ""
        if !value.isEmpty { cacheStore.save(value, for: key, ttl: 30 * 24 * 60 * 60) }
        return value
    }

    func clearArtworkCache() { artworkStore.clear() }
    func clearAudioCache() { audioCache.clear() }

    private func recordRecentPlay(_ track: MusicTrack) {
        userData.recentPlays.removeAll { $0.id == track.id }
        userData.recentPlays.insert(track, at: 0)
        if userData.recentPlays.count > 200 { userData.recentPlays.removeLast(userData.recentPlays.count - 200) }
        userData.revision += 1
        persistUserData()
    }

    private func persistUserData() {
        cacheStore.save(userData, for: "library.userData")
        saveUserDataTask?.cancel()
        let snapshot = userData
        saveUserDataTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? await self?.api.saveUserData(snapshot)
        }
    }

    private func connectWebSocket() {
        Task { [weak self] in
            guard let self, let url = try? await self.api.webSocketURL() else { return }
            self.webSocket.connect(to: url)
        }
    }

    private func handleWebSocketEvent(_ type: String) {
        let relevant = [
            "library:changed", "library:removed", "library:scan-complete",
            "library:user-data-changed", "library:playlists-changed",
        ]
        guard relevant.contains(type) else { return }
        Task { [weak self] in await self?.refreshAll(force: true) }
    }

    private func loadCachedData() {
        tracks = cacheStore.value([MusicTrack].self, for: "library.tracks") ?? []
        albums = cacheStore.value([MusicAlbum].self, for: "library.albums") ?? []
        artists = cacheStore.value([MusicArtist].self, for: "library.artists") ?? []
        genres = cacheStore.value([String].self, for: "library.genres") ?? []
        sources = cacheStore.value([MusicSource].self, for: "search.sources") ?? []
        userData = cacheStore.value(LibraryUserData.self, for: "library.userData") ?? .empty
        loadDiscoverCache(prefix: "discover.\(selectedSourceID)")
    }

    private func loadDiscoverCache(prefix: String) {
        discoverSongs = cacheStore.value([MusicTrack].self, for: prefix + ".songs") ?? []
        discoverAlbums = cacheStore.value([MusicAlbum].self, for: prefix + ".albums") ?? []
        toplists = cacheStore.value([MusicPlaylist].self, for: prefix + ".toplists") ?? []
    }

    private func loadProfile() -> ServerProfile? {
        guard let data = UserDefaults.standard.data(forKey: profileKey) else { return nil }
        return try? JSONDecoder().decode(ServerProfile.self, from: data)
    }

    private func saveProfile() {
        guard let profile, let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: profileKey)
    }

    private func clearAllCachedData() {
        tracks = []
        albums = []
        artists = []
        genres = []
        sources = []
        userData = .empty
        discoverSongs = []
        discoverAlbums = []
        toplists = []
        cacheStore.clearAll()
        audioCache.clear()
        artworkStore.clear()
    }
}
