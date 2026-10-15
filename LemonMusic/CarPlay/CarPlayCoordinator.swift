import CarPlay
import Observation

@MainActor
final class CarPlayCoordinator: NSObject, CPNowPlayingTemplateObserver, CPInterfaceControllerDelegate, CPTabBarTemplateDelegate {
    private enum Content {
        case recent, favorites, playlists, library, playlist(String), queue
    }

    private final class Screen {
        let content: Content
        let template: CPListTemplate
        var page = 0
        var artworkTask: Task<Void, Never>?
        var artwork: [(CPListItem, MusicTrack?, MusicPlaylist?)] = []

        init(_ content: Content, title: String, symbol: String) {
            self.content = content
            template = CPListTemplate(title: title, sections: [])
            template.tabTitle = title
            template.tabImage = UIImage(systemName: symbol)
        }
    }

    private let model: AppModel
    private var interface: (any CarPlayPresenting)?
    private var root: CPTabBarTemplate?
    private let sessionTemplate = CPListTemplate(title: "柠檬音乐", sections: [])
    private var screens: [Screen] = []
    private var connectionID = UUID()
    private var accountGeneration: UUID?
    private var libraryRevision: UUID?
    private var observationTask: Task<Void, Never>?
    private var libraryTask: Task<[MusicTrack], Error>?
    private var libraryPages: [Int: [MusicTrack]] = [:]
    private var libraryError: String?
    private var libraryLoading = false
    private var lastError: String?
    private var isSessionRoot = false
    private var hasRoot = false
    private(set) var isConnected = false

    init(model: AppModel) {
        self.model = model
    }

    func connect(to interface: any CarPlayPresenting) {
        disconnect()
        self.interface = interface
        isConnected = true
        connectionID = UUID()
        screens = [
            Screen(.recent, title: "最近播放", symbol: "clock"),
            Screen(.favorites, title: "我的收藏", symbol: "heart"),
            Screen(.playlists, title: "我的歌单", symbol: "music.note.list"),
            Screen(.library, title: "音乐库", symbol: "music.note.house"),
        ]
        root = CPTabBarTemplate(templates: screens.map(\.template))
        root?.delegate = self
        CPNowPlayingTemplate.shared.add(self)
        configureNowPlaying()
        observe()
        let connection = connectionID
        Task { [weak self, model] in
            await model.bootstrap(includeDiscovery: false)
            guard let self, self.isConnected, self.connectionID == connection else { return }
            self.render()
        }
    }

    func disconnect() {
        isConnected = false
        connectionID = UUID()
        observationTask?.cancel()
        observationTask = nil
        libraryTask?.cancel()
        libraryTask = nil
        screens.forEach { $0.artworkTask?.cancel() }
        screens.removeAll()
        root?.delegate = nil
        root = nil
        interface = nil
        libraryPages.removeAll()
        libraryLoading = false
        libraryError = nil
        accountGeneration = nil
        libraryRevision = nil
        lastError = nil
        isSessionRoot = false
        hasRoot = false
        CPNowPlayingTemplate.shared.remove(self)
    }

    private func observe() {
        guard isConnected else { return }
        let connection = connectionID
        withObservationTracking {
            _ = model.sessionState
            _ = model.sessionGeneration
            _ = model.tracks
            _ = model.libraryRevision
            _ = model.userData
            _ = model.isRefreshing
            _ = model.errorMessage
            _ = model.playback.queueEntries
            _ = model.playback.currentEntryID
            _ = model.playback.isPlaying
            _ = model.playback.mode
            _ = model.playback.lastError
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isConnected, self.connectionID == connection else { return }
                self.observationTask?.cancel()
                self.observationTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, !Task.isCancelled, self.connectionID == connection else { return }
                    self.observe()
                }
            }
        }
        render()
    }

    private func render() {
        guard isConnected, let interface else { return }
        let accountChanged = accountGeneration != model.sessionGeneration
        if accountChanged {
            if accountGeneration != nil { interface.dismissAlert() }
            libraryTask?.cancel()
            libraryTask = nil
            libraryLoading = false
            libraryPages.removeAll()
            libraryError = nil
            screens.forEach { $0.artworkTask?.cancel(); $0.page = 0 }
            screens = Array(screens.prefix(4))
            accountGeneration = model.sessionGeneration
            lastError = nil
            isSessionRoot = false
        }
        if libraryRevision != model.libraryRevision {
            libraryPages.removeAll()
            libraryRevision = model.libraryRevision
        }
        if model.sessionState == .signedOut || model.sessionState == .loading {
            let loading = model.sessionState == .loading
            sessionTemplate.emptyViewTitleVariants = [loading ? "正在恢复音乐库" : "请先登录"]
            sessionTemplate.emptyViewSubtitleVariants = [loading ? "正在连接服务器" : "请在 iPhone 上打开柠檬音乐并登录"]
            if #available(iOS 18.4, *) { sessionTemplate.showsSpinnerWhileEmpty = loading }
            sessionTemplate.updateSections([])
            if accountChanged || !isSessionRoot || !hasRoot {
                interface.setRoot(sessionTemplate)
                isSessionRoot = true
                hasRoot = true
            }
            return
        }
        if let root, accountChanged || isSessionRoot || !hasRoot {
            interface.setRoot(root)
            isSessionRoot = false
            hasRoot = true
            model.playback.publishNowPlaying()
        }
        syncLibraryCache()
        for screen in screens { update(screen) }
        configureNowPlaying()
        if let error = model.playback.lastError, error != lastError {
            lastError = error
            showPlaybackError(error)
        } else if model.playback.lastError == nil {
            lastError = nil
        }
        if let template = interface.templates.last as? CPListTemplate,
           let screen = screens.first(where: { $0.template === template }) {
            loadArtwork(screen)
        } else if let selected = root?.selectedTemplate,
                  let screen = screens.first(where: { $0.template === selected }) {
            loadArtwork(screen)
        }
    }

    private func syncLibraryCache() {
        if let first = model.cachedCarPlayLibraryPage(1) {
            if let previous = libraryPages[1], previous.map(\.id) != first.map(\.id) {
                libraryPages.removeAll()
            }
            libraryPages[1] = first
            var page = 2
            while libraryPages[page - 1]?.count == 200 {
                if libraryPages[page] == nil {
                    guard let cached = model.cachedCarPlayLibraryPage(page) else { break }
                    libraryPages[page] = cached
                }
                page += 1
            }
        }
    }

    private var libraryTracks: [MusicTrack] {
        var result: [MusicTrack] = []
        var seen = Set<String>()
        for page in libraryPages.keys.sorted() {
            for track in libraryPages[page] ?? [] where seen.insert(track.id).inserted { result.append(track) }
        }
        return result
    }

    private func tracks(for content: Content) -> [MusicTrack] {
        switch content {
        case .recent: model.recentTracks
        case .favorites: model.userData.favorites
        case .library: libraryTracks
        case .playlist(let id): model.userData.playlists.first { $0.id == id }?.tracks ?? []
        case .queue: model.playback.queue
        case .playlists: []
        }
    }

    private func update(_ screen: Screen) {
        screen.artworkTask?.cancel()
        screen.artworkTask = nil
        screen.artwork.removeAll()
        screen.template.trailingNavigationBarButtons = navigationBarButtons()
        if case .playlists = screen.content {
            updatePlaylists(screen)
            return
        }
        let tracks = tracks(for: screen.content)
        let entries = model.playback.queueEntries
        let pagination = pagination(count: tracks.count, page: screen.page)
        screen.page = pagination.page
        var items: [CPListItem] = []
        if !tracks.isEmpty, !isQueue(screen.content) {
            items.append(action("播放全部", detail: "\(tracks.count) 首", symbol: "play.fill") { [weak self] in
                guard let self else { return }
                let index = self.model.playback.mode == .shuffled ? Int.random(in: tracks.indices) : 0
                await self.play(at: index, tracks: tracks)
            })
        }
        for index in pagination.range {
            let track = tracks[index]
            let entryID = isQueue(screen.content) ? entries[index].id : nil
            let item = action(track.title, detail: track.artist, symbol: "music.note") { [weak self] in
                guard let self else { return }
                if let entryID { await self.playQueueEntry(entryID) }
                else { await self.play(at: index, tracks: tracks) }
            }
            item.isPlaying = model.playback.isPlaying && (entryID.map { $0 == model.playback.currentEntryID } ??
                (model.playback.queueEntries.first { $0.id == model.playback.currentEntryID }?.track.id == track.id))
            item.playingIndicatorLocation = .trailing
            screen.artwork.append((item, track, nil))
            items.append(item)
        }
        appendPagination(to: &items, screen: screen, pagination: pagination)
        if case .library = screen.content {
            let page = (libraryPages.keys.max() ?? 0) + 1
            let hasMore = libraryPages.isEmpty || libraryPages[page - 1]?.count == 200
            if !pagination.hasNext, hasMore || libraryError != nil {
                let item = action(libraryError == nil ? "更多歌曲" : "重试加载", detail: libraryError, symbol: "arrow.clockwise") { [weak self] in
                    await self?.loadLibraryPage(page, force: true)
                }
                item.isEnabled = !libraryLoading
                if libraryLoading { item.setText("正在加载") }
                items.append(item)
            }
        }
        screen.template.emptyViewTitleVariants = ["暂无歌曲"]
        screen.template.emptyViewSubtitleVariants = [
            model.sessionState == .offline ? "当前离线，可播放已缓存的歌曲" : "请在 iPhone 上添加歌曲或歌单",
        ]
        screen.template.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }

    private func updatePlaylists(_ screen: Screen) {
        let playlists = model.userData.playlists
        let pagination = pagination(count: playlists.count, page: screen.page)
        screen.page = pagination.page
        var items: [CPListItem] = []
        for index in pagination.range {
            let playlist = playlists[index]
            let item = action(playlist.name, detail: "\(playlist.tracks.count) 首", symbol: "music.note.list") { [weak self] in
                self?.openPlaylist(id: playlist.id)
            }
            item.accessoryType = .disclosureIndicator
            screen.artwork.append((item, nil, playlist))
            items.append(item)
        }
        appendPagination(to: &items, screen: screen, pagination: pagination)
        screen.template.emptyViewTitleVariants = ["还没有歌单"]
        screen.template.emptyViewSubtitleVariants = ["请在 iPhone 上创建或收藏歌单"]
        screen.template.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }

    private func pagination(count: Int, page: Int) -> CarPlayPagination {
        CarPlayPagination(count: count, page: page, maximumItems: max(5, CPListTemplate.maximumItemCount))
    }

    private func appendPagination(to items: inout [CPListItem], screen: Screen, pagination: CarPlayPagination) {
        if pagination.hasPrevious {
            items.append(action("上一页", detail: nil, symbol: "chevron.left") { [weak self, weak screen] in
                guard let self, let screen else { return }
                screen.page -= 1
                self.update(screen)
                self.loadArtwork(screen)
                await self.refreshLibraryPage(for: screen)
            })
        }
        if pagination.hasNext {
            items.append(action("下一页", detail: "\(pagination.page + 1)/\(pagination.pageCount)", symbol: "chevron.right") { [weak self, weak screen] in
                guard let self, let screen else { return }
                screen.page += 1
                self.update(screen)
                self.loadArtwork(screen)
                await self.refreshLibraryPage(for: screen)
            })
        }
    }

    private func action(
        _ title: String, detail: String?, symbol: String,
        perform: @escaping @MainActor () async -> Void
    ) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail, image: UIImage(systemName: symbol))
        let connection = connectionID
        let account = model.sessionGeneration
        item.handler = { [weak self] _, completion in
            Task { @MainActor [weak self] in
                defer { completion() }
                guard let self, self.isConnected, self.connectionID == connection,
                      self.model.sessionGeneration == account, self.model.sessionState != .signedOut else { return }
                await perform()
            }
        }
        return item
    }

    private func openPlaylist(id: String) {
        guard let playlist = model.userData.playlists.first(where: { $0.id == id }) else { return }
        let screen = Screen(.playlist(id), title: playlist.name, symbol: "music.note.list")
        retainDetail(screen)
        update(screen)
        interface?.push(screen.template)
        loadArtwork(screen)
    }

    private func retainDetail(_ screen: Screen) {
        let active = interface?.templates ?? []
        screens = Array(screens.prefix(4)) + screens.dropFirst(4).filter { detail in
            let retained = active.contains { $0 === detail.template }
            if !retained { detail.artworkTask?.cancel() }
            return retained
        }
        screens.append(screen)
    }

    private func play(at index: Int, tracks: [MusicTrack]) async {
        await model.play(at: index, in: tracks)
        guard isConnected, model.sessionState != .signedOut else { return }
        if model.playback.lastError == nil { showNowPlaying() }
    }

    private func playQueueEntry(_ id: UUID) async {
        await model.playQueueEntry(id: id)
        guard isConnected, model.sessionState != .signedOut else { return }
        if model.playback.lastError == nil { showNowPlaying() }
    }

    private func navigationBarButtons() -> [CPBarButton] {
        var buttons: [CPBarButton] = []
        if model.sessionState == .offline {
            let retry = CPBarButton(image: UIImage(systemName: "arrow.clockwise")!) { [weak self] _ in
                guard let self else { return }
                Task { await self.model.refreshAll(force: false, includeDiscovery: false) }
            }
            retry.isEnabled = !model.isRefreshing
            buttons.append(retry)
        }
        return buttons
    }

    private func showNowPlaying() {
        guard let interface, model.playback.currentTrack != nil else { return }
        model.playback.publishNowPlaying()
        let nowPlaying = CPNowPlayingTemplate.shared
        if interface.templates.last === nowPlaying { return }
        if interface.templates.contains(where: { $0 === nowPlaying }) { interface.pop(to: nowPlaying) }
        else { interface.push(nowPlaying) }
    }

    private func configureNowPlaying() {
        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = !model.playback.queue.isEmpty
        template.upNextTitle = "播放队列"
        template.isAlbumArtistButtonEnabled = false
        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
            guard let playback = self?.model.playback else { return }
            playback.setMode(playback.mode == .shuffled ? .sequential : .shuffled)
        }
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            guard let playback = self?.model.playback else { return }
            playback.setMode(playback.mode == .repeatOne ? .sequential : .repeatOne)
        }
        shuffle.isEnabled = model.playback.currentTrack != nil
        repeatButton.isEnabled = model.playback.currentTrack != nil
        template.updateNowPlayingButtons([shuffle, repeatButton])
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard isConnected, !model.playback.queue.isEmpty else { return }
        let screen = Screen(.queue, title: "播放队列", symbol: "list.bullet")
        screen.page = pagination(count: model.playback.queue.count, page: 0).range.count > 0
            ? model.playback.currentIndex / pagination(count: model.playback.queue.count, page: 0).range.count : 0
        retainDetail(screen)
        update(screen)
        interface?.push(screen.template)
        loadArtwork(screen)
    }

    private func isQueue(_ content: Content) -> Bool {
        if case .queue = content { return true }
        return false
    }

    private func loadLibraryPage(_ page: Int, force: Bool = false) async {
        guard !libraryLoading, isConnected else { return }
        let connection = connectionID
        let account = model.sessionGeneration
        libraryLoading = true
        libraryError = nil
        render()
        let task = Task { try await model.carPlayLibraryPage(page, force: force) }
        libraryTask = task
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        guard isConnected, connectionID == connection, model.sessionGeneration == account else { return }
        libraryTask = nil
        libraryLoading = false
        switch result {
        case .success(let tracks):
            libraryPages[page] = tracks
        case .failure(let error):
            if !(error is CancellationError) { libraryError = error.localizedDescription }
        }
        render()
    }

    private func loadArtwork(_ screen: Screen) {
        guard isConnected, screen.artworkTask == nil, let interface else { return }
        let connection = connectionID
        let account = model.sessionGeneration
        let scale = max(1, interface.imageScale)
        let size = CGSize(width: CPListItem.maximumImageSize.width * scale, height: CPListItem.maximumImageSize.height * scale)
        // Only the current page loads artwork, sequentially, without prefetching other tabs.
        let artwork = screen.artwork
        screen.artworkTask = Task { [weak self, weak screen] in
            guard let self, let screen else { return }
            for (item, track, playlist) in artwork {
                guard !Task.isCancelled, self.isConnected, self.connectionID == connection,
                      self.model.sessionGeneration == account else { return }
                let image: UIImage?
                if let track {
                    image = await self.model.artworkStore.image(for: track, api: self.model.api)
                } else if let playlist, let url = playlist.artworkURL {
                    image = await self.model.artworkStore.image(key: "playlist:\(playlist.id)", remoteURL: url, api: self.model.api)
                } else if let track = playlist?.tracks.first {
                    image = await self.model.artworkStore.image(for: track, api: self.model.api)
                } else { image = nil }
                guard !Task.isCancelled, self.isConnected, self.connectionID == connection,
                      self.model.sessionGeneration == account else { return }
                if let image { item.setImage(image.preparingThumbnail(of: size) ?? image) }
            }
            screen.artworkTask = nil
        }
    }

    private func showPlaybackError(_ error: String) {
        interface?.present(CPAlertTemplate(titleVariants: ["播放失败：\(error)", "播放失败"], actions: [
            CPAlertAction(title: "重试", style: .default) { [weak self] _ in
                self?.interface?.dismissAlert()
                self?.lastError = nil
                self?.model.playback.resume()
            },
            CPAlertAction(title: "关闭", style: .cancel) { [weak self] _ in self?.interface?.dismissAlert() },
        ]))
    }

    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        guard isConnected, let screen = screens.first(where: { $0.template === aTemplate }) else { return }
        update(screen)
        loadArtwork(screen)
        Task { [weak self, weak screen] in
            guard let self, let screen else { return }
            await self.refreshLibraryPage(for: screen)
        }
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        templateWillAppear(selectedTemplate, animated: false)
    }

    private func refreshLibraryPage(for screen: Screen) async {
        guard case .library = screen.content, !model.isRefreshing else { return }
        let visible = pagination(count: libraryTracks.count, page: screen.page).range
        await loadLibraryPage(visible.lowerBound / 200 + 1)
    }
}
