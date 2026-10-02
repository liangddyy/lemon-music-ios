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
    private(set) var toplists: [MusicPlaylist] = []
    private(set) var discoverPlaylists: [MusicPlaylist] = []
    private(set) var onlineSearchResults: [MusicTrack] = []
    private(set) var onlineSearchAlbums: [MusicAlbum] = []
    private(set) var onlineSearchPlaylists: [MusicPlaylist] = []
    private(set) var isRefreshing = false
    private(set) var isSearching = false
    private(set) var discoverError: String?
    var errorMessage: String?
    private(set) var userDataSyncError: String?
    private var pendingUserDataSync = false

    var selectedSourceID: String {
        didSet { preferences.set(selectedSourceID, forKey: "lemon.selectedSource") }
    }

    let api: LemonAPIClient
    let cacheStore: CacheStore
    let audioCache: AudioCache
    let artworkStore = ArtworkStore()
    let playback: PlaybackController
    let collectionCache: CollectionCacheCoordinator
    let nasDownloads: NASDownloadCoordinator
    let webSocket = LemonWebSocket()

    private let keychain = KeychainStore()
    private let profileKey = "lemon.serverProfile"
    private let tokenKey = "session-token"
    private let preferences: UserDefaults
    private var saveUserDataTask: Task<Void, Never>?
    private var discoverRequests: [String: UUID] = [:]
    private var localMatchTasks: [String: Task<MusicTrack?, Never>] = [:]
    private var searchRequestID: UUID?

    var isRefreshingDiscover: Bool { discoverRequests[selectedSourceID] != nil }

    init(inMemory: Bool = false, api: LemonAPIClient = LemonAPIClient()) throws {
        self.api = api
        preferences = inMemory ? UserDefaults(suiteName: "lemon.tests.\(UUID())")! : .standard
        cacheStore = try CacheStore(inMemory: inMemory)
        audioCache = AudioCache(
            container: cacheStore.container,
            root: inMemory ? FileManager.default.temporaryDirectory.appendingPathComponent("lemon-tests-\(UUID())") : nil
        )
        playback = PlaybackController(api: api, audioCache: audioCache, artworkStore: artworkStore, defaults: preferences)
        collectionCache = CollectionCacheCoordinator(
            api: api, audioCache: audioCache, store: cacheStore, background: !inMemory, monitorNetwork: !inMemory
        )
        nasDownloads = NASDownloadCoordinator(api: api, store: cacheStore)
        selectedSourceID = preferences.string(forKey: "lemon.selectedSource") ?? "kw"
        playback.preferredTrack = { [weak self] track in
            guard let self else { return track }
            return await self.preferredLocalTrack(for: track)
        }
        collectionCache.preferredTrack = { [weak self] track in await self?.preferredLocalTrack(for: track) ?? track }
        nasDownloads.preferredTrack = { [weak self] track in await self?.preferredLocalTrack(for: track) ?? track }
        playback.willPlayTrack = { [weak self] track in await self?.collectionCache.givePlaybackPriority(to: track) }
        playback.onTrackChanged = { [weak self] in self?.collectionCache.pump() }
        webSocket.onEvent = { [weak self] type in self?.handleWebSocketEvent(type) }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingReset") {
            keychain.delete(tokenKey)
            UserDefaults.standard.removeObject(forKey: profileKey)
            cacheStore.clearAll()
            audioCache.clear()
            artworkStore.clear()
        } else if !inMemory, let saved = loadProfile() {
            collectionCache.configure(account: accountKey(saved), activate: false)
        }
    }

    var favoriteIDs: Set<String> { Set(userData.favorites.map(\.id)) }
    var recentTracks: [MusicTrack] { userData.recentPlays }
    var recentlyAdded: [MusicTrack] {
        tracks.sorted { ($0.modifiedAt ?? 0) > ($1.modifiedAt ?? 0) }.prefix(30).map { $0 }
    }

    func bootstrap() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestingFixtures") {
            await loadUITestFixtures()
            return
        }
        #endif
        loadCachedData()
        guard let profile = loadProfile(), let token = keychain.get(tokenKey) else {
            sessionState = .signedOut
            return
        }
        self.profile = profile
        do {
            try await api.configure(baseURL: profile.baseURL, token: token, apiPrefix: profile.apiPrefix)
            configureDownloads()
            sessionState = tracks.isEmpty ? .loading : .ready
            let user = try await api.currentUser()
            self.profile?.user = user
            self.profile?.apiPrefix = await api.selectedAPIPrefix()
            saveProfile()
            configureDownloads()
            sessionState = .ready
            connectWebSocket()
            await refreshAll(force: false)
        } catch LemonAPIClient.APIError.unauthorized {
            collectionCache.reset()
            nasDownloads.reset()
            keychain.delete(tokenKey)
            sessionState = .signedOut
        } catch {
            sessionState = tracks.isEmpty ? .signedOut : .offline
            errorMessage = tracks.isEmpty ? "无法连接服务器，请检查地址和网络" : nil
        }
    }

    func login(baseURL: String, username: String, password: String) async throws {
        let previousProfile = profile ?? loadProfile()
        saveUserDataTask?.cancel()
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        try await api.configure(baseURL: normalized, token: nil)
        let session = try await api.login(username: username, password: password)
        try keychain.set(session.token, for: tokenKey)
        let nextProfile = ServerProfile(
            baseURL: normalized,
            username: username,
            user: session.user,
            apiPrefix: await api.selectedAPIPrefix()
        )
        if previousProfile.map({ accountKey($0) != accountKey(nextProfile) }) ?? true {
            collectionCache.reset()
            nasDownloads.reset()
            playback.stop()
            clearAllCachedData()
        }
        profile = nextProfile
        saveProfile()
        sessionState = .ready
        configureDownloads()
        connectWebSocket()
        await refreshAll(force: true)
    }

    func logout() async {
        collectionCache.reset()
        nasDownloads.reset()
        saveUserDataTask?.cancel()
        playback.stop()
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestingFixtures") { return }
        #endif
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
            if !pendingUserDataSync { userData = values.5 }
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
            await refreshDiscover(force: false)
        } catch LemonAPIClient.APIError.unauthorized {
            collectionCache.reset()
            nasDownloads.reset()
            keychain.delete(tokenKey)
            sessionState = .signedOut
        } catch {
            sessionState = tracks.isEmpty ? .offline : sessionState
            errorMessage = error.localizedDescription
        }
    }

    func refreshDiscover(force: Bool = false) async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestingFixtures") { return }
        #endif
        guard !selectedSourceID.isEmpty else { return }
        let source = selectedSourceID
        guard discoverRequests[source] == nil else { return }
        let cachePrefix = "discover.\(source)"
        let cacheKeys = [".songs", ".toplists", ".playlists"].map { cachePrefix + $0 }
        func needsRefresh(_ suffix: String) -> Bool {
            force || (!cacheStore.isFresh(cachePrefix + suffix) && !cacheStore.isFresh(cachePrefix + suffix + ".error"))
        }
        let fetchSongs = needsRefresh(".songs")
        let fetchLists = needsRefresh(".toplists")
        let fetchPlaylists = needsRefresh(".playlists")
        var failures: [String] = force ? [] : cacheKeys.compactMap {
            cacheStore.value(String.self, for: $0 + ".error", allowExpired: false)
        }
        if !fetchSongs, !fetchLists, !fetchPlaylists {
            loadDiscoverCache(prefix: cachePrefix)
            discoverError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            return
        }
        let requestID = UUID()
        discoverRequests[source] = requestID
        discoverError = nil
        defer { if discoverRequests[source] == requestID { discoverRequests[source] = nil } }
        let songsTask = Task {
            if fetchSongs { return try await api.newSongs(source: source) }
            return cacheStore.value([MusicTrack].self, for: cachePrefix + ".songs") ?? []
        }
        let listsTask = Task {
            if fetchLists { return try await api.toplists(source: source) }
            return cacheStore.value([MusicPlaylist].self, for: cachePrefix + ".toplists") ?? []
        }
        let playlistsTask = Task {
            if fetchPlaylists { return try await api.recommendedPlaylists(source: source) }
            return cacheStore.value([MusicPlaylist].self, for: cachePrefix + ".playlists") ?? []
        }
        let results = await (songsTask.result, listsTask.result, playlistsTask.result)
        guard discoverRequests[source] == requestID else { return }
        let ttl: TimeInterval = 6 * 60 * 60
        func recordFailure(_ error: Error, label: String, suffix: String) {
            let message = "\(label)：\(error.localizedDescription)"
            failures.append(message)
            cacheStore.save(message, for: cachePrefix + suffix + ".error", ttl: 10 * 60)
        }
        func clearFailure(_ suffix: String) {
            cacheStore.save("", for: cachePrefix + suffix + ".error", ttl: -1)
        }
        switch results.0 {
        case .success(let songs):
            if fetchSongs {
                cacheStore.save(songs, for: cachePrefix + ".songs", ttl: ttl)
                clearFailure(".songs")
            }
        case .failure(let error): recordFailure(error, label: "新歌", suffix: ".songs")
        }
        switch results.1 {
        case .success(let lists):
            if fetchLists {
                cacheStore.save(lists, for: cachePrefix + ".toplists", ttl: ttl)
                clearFailure(".toplists")
            }
        case .failure(let error): recordFailure(error, label: "排行榜", suffix: ".toplists")
        }
        switch results.2 {
        case .success(let playlists):
            if fetchPlaylists {
                cacheStore.save(playlists, for: cachePrefix + ".playlists", ttl: ttl)
                clearFailure(".playlists")
            }
        case .failure(let error): recordFailure(error, label: "歌单", suffix: ".playlists")
        }
        if selectedSourceID == source {
            loadDiscoverCache(prefix: cachePrefix)
            discoverError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }

    func collectionTracks(_ collection: OnlineCollection, page: Int = 1, force: Bool = false) async throws -> TrackPage {
        let key = "\(collection.cacheKey).page.\(page)"
        if !force, let cached: TrackPage = cacheStore.value(TrackPage.self, for: key, allowExpired: false) {
            return cached
        }
        let result = try await api.collectionTracks(collection, page: page)
        cacheStore.save(result, for: key, ttl: 6 * 60 * 60)
        return result
    }

    func cachedCollectionPage(_ collection: OnlineCollection, page: Int = 1) -> TrackPage? {
        cacheStore.value(TrackPage.self, for: "\(collection.cacheKey).page.\(page)")
    }

    func collectionPage(_ source: CollectionSource, page: Int, force: Bool = false) async throws -> TrackPage {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestingFixtures") {
            return TrackPage(tracks: tracks, total: tracks.count)
        }
        #endif
        switch source {
        case .playlist(let playlist):
            let current = userData.playlists.first { $0.id == playlist.id } ?? playlist
            return TrackPage(tracks: current.tracks, total: current.tracks.count)
        case .online(let collection):
            return try await collectionTracks(collection, page: page, force: force)
        case .local(let collection):
            let key = "\(collection.cacheKey).page.\(page)"
            if !force, let cached = cacheStore.value(TrackPage.self, for: key, allowExpired: false) { return cached }
            let result = try await api.localCollectionTracks(collection, page: page)
            cacheStore.save(result, for: key, ttl: 10 * 60)
            return result
        }
    }

    func completeCollection(_ source: CollectionSource, force: Bool = false) async throws -> [MusicTrack] {
        var result = CollectionAccumulator()
        var page = 1
        repeat {
            try Task.checkCancellation()
            try result.append(await collectionPage(source, page: page, force: force))
            if case .online(let online) = source, online.kind == .playlist, !result.isComplete {
                throw CollectionError.incomplete
            }
            page += 1
        } while !result.isComplete
        cacheStore.save(TrackPage(tracks: result.tracks, total: result.total), for: "\(source.key).complete", ttl: 6 * 60 * 60)
        return result.tracks
    }

    func cachedCompleteCollection(_ source: CollectionSource) -> TrackPage? {
        cacheStore.value(TrackPage.self, for: "\(source.key).complete")
    }

    func isCollectionFavorite(_ source: CollectionSource) -> Bool {
        guard let identity = source.favoriteIdentity else { return false }
        return userData.playlists.contains {
            $0.isImported && $0.importSource == identity.source
                && $0.importURL.map(PlaylistIdentity.canonicalID) == PlaylistIdentity.canonicalID(identity.id)
        }
    }

    func favoriteCollection(_ source: CollectionSource, tracks: [MusicTrack]) {
        guard let identity = source.favoriteIdentity, !isCollectionFavorite(source) else { return }
        var playlist = MusicPlaylist(name: source.title, tracks: tracks, artworkURL: source.artworkURL)
        playlist.preservedFields = [
            "playlistType": .string("imported"), "importSource": .string(identity.source),
            "importUrl": .string(identity.id), "lastSyncedAt": .number(Date().timeIntervalSince1970 * 1_000),
            "lastRemoteSyncedAt": .number(Date().timeIntervalSince1970 * 1_000), "remoteAutoSync": .bool(true),
        ]
        userData.playlists.insert(playlist, at: 0)
        userData.revision += 1
        persistUserData()
    }

    func unfavoriteCollection(_ source: CollectionSource) {
        guard let identity = source.favoriteIdentity else { return }
        userData.playlists.removeAll {
            $0.isImported && $0.importSource == identity.source
                && $0.importURL.map(PlaylistIdentity.canonicalID) == PlaylistIdentity.canonicalID(identity.id)
        }
        userData.revision += 1
        persistUserData()
    }

    func playAll(_ tracks: [MusicTrack]) async {
        let first = playback.mode == .shuffled ? tracks.randomElement() : tracks.first
        guard let first else { return }
        await play(first, in: tracks)
    }

    func retryUserDataSync() async {
        saveUserDataTask?.cancel()
        await syncUserData(userData)
    }

    private struct LocalMatchSnapshot: Codable { let track: MusicTrack? }

    func preferredLocalTrack(for track: MusicTrack) async -> MusicTrack {
        guard track.locator.kind == .online else { return track }
        if let matched = LocalTrackMatcher.bestMatch(for: track, in: tracks) { return matched }
        let key = "local-match.v1.\(track.id)"
        if let snapshot: LocalMatchSnapshot = cacheStore.value(LocalMatchSnapshot.self, for: key, allowExpired: false) {
            return snapshot.track ?? track
        }
        if let task = localMatchTasks[track.id] { return await task.value ?? track }
        let task = Task<MusicTrack?, Never> { [weak self] in
            guard let self else { return nil }
            do {
                for page in 1...3 {
                    let candidates = try await self.api.tracks(page: page, limit: 200, query: track.title, sort: "title")
                    guard !Task.isCancelled else { return nil }
                    if let matched = LocalTrackMatcher.bestMatch(for: track, in: candidates) {
                        self.cacheStore.save(LocalMatchSnapshot(track: matched), for: key, ttl: 10 * 60)
                        return matched
                    }
                    if candidates.count < 200 { break }
                }
                guard !Task.isCancelled else { return nil }
                self.cacheStore.save(LocalMatchSnapshot(track: nil), for: key, ttl: 10 * 60)
            } catch {
                // A failed library lookup must not prevent online playback.
            }
            return nil
        }
        localMatchTasks[track.id] = task
        let matched = await task.value
        localMatchTasks[track.id] = nil
        return matched ?? track
    }

    func selectSource(_ id: String, refreshDiscovery: Bool = true) async {
        selectedSourceID = id
        loadDiscoverCache(prefix: "discover.\(id)")
        if refreshDiscovery { await refreshDiscover(force: false) }
    }

    func searchOnline(_ query: String, kind: OnlineSearchKind = .songs) async {
        let requestID = UUID()
        searchRequestID = requestID
        isSearching = false
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            onlineSearchResults = []
            onlineSearchAlbums = []
            onlineSearchPlaylists = []
            return
        }
        let source = selectedSourceID
        let cacheKey = "search.v2.\(kind.id.rawValue).\(source).\(value.lowercased())"
        switch kind {
        case .songs:
            if let cached: [MusicTrack] = cacheStore.value([MusicTrack].self, for: cacheKey, allowExpired: false) {
                onlineSearchResults = cached
                return
            }
        case .albums:
            if let cached: [MusicAlbum] = cacheStore.value([MusicAlbum].self, for: cacheKey, allowExpired: false) {
                onlineSearchAlbums = cached
                return
            }
        case .playlists:
            if let cached: [MusicPlaylist] = cacheStore.value([MusicPlaylist].self, for: cacheKey, allowExpired: false) {
                onlineSearchPlaylists = cached
                return
            }
        }
        isSearching = true
        defer { if searchRequestID == requestID { isSearching = false } }
        do {
            switch kind {
            case .songs:
                let result = try await api.searchTracks(keyword: value, source: source)
                guard searchRequestID == requestID, !Task.isCancelled else { return }
                onlineSearchResults = result
                cacheStore.save(result, for: cacheKey, ttl: 15 * 60)
            case .albums:
                let result = try await api.searchAlbums(keyword: value, source: source)
                guard searchRequestID == requestID, !Task.isCancelled else { return }
                onlineSearchAlbums = result
                cacheStore.save(result, for: cacheKey, ttl: 15 * 60)
            case .playlists:
                let result = try await api.searchPlaylists(keyword: value, source: source)
                guard searchRequestID == requestID, !Task.isCancelled else { return }
                onlineSearchPlaylists = result
                cacheStore.save(result, for: cacheKey, ttl: 15 * 60)
            }
        } catch {
            if searchRequestID == requestID, !Task.isCancelled { errorMessage = error.localizedDescription }
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestingFixtures") {
            return "[00:00.00]柠檬音乐\n[00:05.00]夜色里的旋律\n[00:10.00]让音乐陪伴每一天"
        }
        #endif
        let key = "lyrics.v2.\(track.id)"
        if let cached: String = cacheStore.value(String.self, for: key, allowExpired: false) { return cached }
        let value = (try? await api.lyrics(for: track)) ?? ""
        if !value.isEmpty { cacheStore.save(value, for: key, ttl: 30 * 24 * 60 * 60) }
        return value
    }

    func clearArtworkCache() { artworkStore.clear() }
    func clearAudioCache() {
        collectionCache.reset()
        if let profile { collectionCache.configure(account: accountKey(profile)) }
        playback.cancelAutomaticCaching()
        audioCache.clear()
    }

    private func recordRecentPlay(_ track: MusicTrack) {
        userData.recentPlays.removeAll { $0.id == track.id }
        userData.recentPlays.insert(track, at: 0)
        if userData.recentPlays.count > 200 { userData.recentPlays.removeLast(userData.recentPlays.count - 200) }
        userData.revision += 1
        persistUserData()
    }

    private func persistUserData() {
        cacheStore.save(userData, for: "library.userData")
        pendingUserDataSync = true
        cacheStore.save(true, for: "library.userData.pending")
        saveUserDataTask?.cancel()
        let snapshot = userData
        saveUserDataTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.syncUserData(snapshot)
        }
    }

    private func syncUserData(_ snapshot: LibraryUserData) async {
        do {
            try Task.checkCancellation()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiTestingFixtures") {
                pendingUserDataSync = false
                userDataSyncError = nil
                return
            }
            #endif
            try await api.saveUserData(snapshot)
            guard !Task.isCancelled else { return }
            userDataSyncError = nil
            if snapshot.revision == userData.revision {
                pendingUserDataSync = false
                cacheStore.save(false, for: "library.userData.pending")
            }
        } catch {
            guard !Task.isCancelled else { return }
            userDataSyncError = error.localizedDescription
        }
    }

    private func accountKey(_ profile: ServerProfile) -> String {
        var server = URLComponents(string: profile.baseURL)
        let path = server?.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression) ?? ""
        server?.path = path
        return "\(server?.string ?? profile.baseURL)|\(profile.user?.id ?? profile.username)"
    }

    private func configureDownloads() {
        guard let profile else { return }
        collectionCache.configure(account: accountKey(profile))
        nasDownloads.configure(account: accountKey(profile))
        if pendingUserDataSync { Task { await retryUserDataSync() } }
    }

    private func connectWebSocket() {
        Task { [weak self] in
            guard let self, let url = try? await self.api.webSocketURL() else { return }
            self.webSocket.connect(to: url)
        }
    }

    private func handleWebSocketEvent(_ type: String) {
        if type.hasPrefix("download:") {
            Task { await nasDownloads.refresh() }
            return
        }
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
        pendingUserDataSync = cacheStore.value(Bool.self, for: "library.userData.pending") ?? false
        loadDiscoverCache(prefix: "discover.\(selectedSourceID)")
    }

    private func loadDiscoverCache(prefix: String) {
        discoverSongs = cacheStore.value([MusicTrack].self, for: prefix + ".songs") ?? []
        toplists = cacheStore.value([MusicPlaylist].self, for: prefix + ".toplists") ?? []
        discoverPlaylists = cacheStore.value([MusicPlaylist].self, for: prefix + ".playlists") ?? []
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
        localMatchTasks.values.forEach { $0.cancel() }
        localMatchTasks.removeAll()
        searchRequestID = nil
        isSearching = false
        onlineSearchResults = []
        onlineSearchAlbums = []
        onlineSearchPlaylists = []
        discoverRequests.removeAll()
        discoverError = nil
        playback.cancelAutomaticCaching()
        tracks = []
        albums = []
        artists = []
        genres = []
        sources = []
        userData = .empty
        pendingUserDataSync = false
        userDataSyncError = nil
        discoverSongs = []
        toplists = []
        discoverPlaylists = []
        cacheStore.clearAll()
        audioCache.clear()
        artworkStore.clear()
    }

    #if DEBUG
    private func loadUITestFixtures() async {
        tracks = ["夜曲", "晴天", "稻香"].enumerated().compactMap { index, name in
            MusicTrack(json: .object([
                "filePath": .string("/fixtures/\(index).wav"), "title": .string(name),
                "artist": .string("周杰伦"), "album": .string("精选"), "duration": .number(20),
                "mtime": .number(Double(index)),
            ]))
        }
        var imported = MusicPlaylist(id: "fixture-imported", name: "午后音乐", tracks: tracks)
        imported.preservedFields = ["playlistType": .string("imported"), "importSource": .string("wy"), "importUrl": .string("fixture")]
        userData = LibraryUserData(
            playlists: [MusicPlaylist(id: "fixture-custom", name: "我的精选", tracks: tracks), imported],
            favorites: Array(tracks.prefix(1)), recentPlays: Array(tracks.prefix(1)), revision: 0
        )
        albums = [MusicAlbum(json: .object(["id": .string("album"), "title": .string("精选"), "artist": .string("周杰伦")]))].compactMap { $0 }
        artists = [MusicArtist(json: .object(["id": .string("artist"), "name": .string("周杰伦")]))].compactMap { $0 }
        genres = ["流行"]
        sources = [MusicSource(id: "wy", name: "网易云")]
        selectedSourceID = "wy"
        toplists = [MusicPlaylist(id: "wy:rank", name: "热歌榜")]
        discoverPlaylists = [MusicPlaylist(id: "wy:fixture", name: "午后音乐")]
        discoverSongs = tracks
        profile = ServerProfile(baseURL: "https://fixtures.invalid", username: "fixture", user: nil, apiPrefix: "/api")
        sessionState = .ready
        playback.setMode(.sequential)
        playback.preferredTrack = nil
        collectionCache.preferredTrack = nil
        collectionCache.configure(account: "fixture")
        nasDownloads.configure(account: "fixture")
        let audio = UITestAudio.silence()
        for track in tracks {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try audio.write(to: url)
                _ = try audioCache.storeDownloadedFile(at: url, key: track.id, mimeType: "audio/wav", protectedKey: nil)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    #endif
}
