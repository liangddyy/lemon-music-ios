import SwiftUI

struct CollectionDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: CollectionSource
    @State private var tracks: [MusicTrack] = []
    @State private var loading = false
    @State private var complete = false
    @State private var errorMessage: String?
    @State private var search = ""
    @State private var searching = false
    @State private var sheet: Sheet?
    @State private var confirmingUnfavorite = false
    @State private var confirmingCellular = false
    private enum Sheet: String, Identifiable {
        case nasOptions, tasks
        var id: Self { self }
    }

    private var fullTracks: [MusicTrack] {
        if case .playlist(let playlist) = source {
            return model.userData.playlists.first(where: { $0.id == playlist.id })?.tracks ?? playlist.tracks
        }
        return tracks
    }

    private var canAct: Bool { complete && !loading && errorMessage == nil && !fullTracks.isEmpty }
    private var favorite: Bool { model.isCollectionFavorite(source) }

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
            actionArea.listRowSeparator(.hidden)
            if loading { ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden) }
            if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
                    Button("重试", systemImage: "arrow.clockwise") { Task { await load(force: true) } }
                }
                .listRowSeparator(.hidden)
            }
            if let error = model.userDataSyncError {
                VStack(alignment: .leading, spacing: 8) {
                    Text("收藏同步失败：\(error)").font(.footnote).foregroundStyle(.red)
                    Button("重试同步", systemImage: "arrow.clockwise") { Task { await model.retryUserDataSync() } }
                }
                .listRowSeparator(.hidden)
            }
            ForEach(fullTracks.matching(search)) { track in TrackRow(track: track, queue: fullTracks) }
            if !loading, fullTracks.matching(search).isEmpty {
                EmptyContentView(
                    title: search.isEmpty ? "暂无歌曲" : "没有找到结果",
                    systemImage: "music.note.list",
                    message: search.isEmpty ? "当前列表没有可用歌曲" : "换个关键词试试"
                )
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CollectionSearchPresentation(query: $search, isPresented: $searching))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("搜索", systemImage: "magnifyingglass") { searching = true }
                    .accessibilityIdentifier("collection.search")
            }
        }
        .onChange(of: searching) { _, value in if !value { search = "" } }
        .task(id: source.key) { await load() }
        .refreshable { await load(force: true) }
        .sheet(item: $sheet) { value in
            switch value {
            case .nasOptions: NASDownloadOptions(key: source.key, title: source.title, tracks: fullTracks)
            case .tasks: CollectionTasksSheet(collectionKey: source.key)
            }
        }
        .confirmationDialog("取消收藏此歌单？", isPresented: $confirmingUnfavorite, titleVisibility: .visible) {
            Button("取消收藏", role: .destructive) {
                model.unfavoriteCollection(source)
                dismiss()
            }
        }
        .confirmationDialog("使用蜂窝流量缓存 \(fullTracks.count) 首歌曲？", isPresented: $confirmingCellular, titleVisibility: .visible) {
            Button("使用蜂窝流量") { startCache(allowsCellular: true) }
            Button("等待 Wi-Fi") { startCache(allowsCellular: false) }
        }
        .accessibilityIdentifier("collection.detail")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PlaylistArtwork(
                playlist: MusicPlaylist(id: source.key, name: source.title, tracks: fullTracks, artworkURL: source.artworkURL),
                size: 96, cacheKey: source.artworkCacheKey
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(source.title).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                Text(source.subtitle).font(.subheadline).foregroundStyle(.secondary)
                Text("\(fullTracks.count) 首" + totalDuration).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var totalDuration: String {
        let seconds = fullTracks.reduce(0) { $0 + $1.duration }
        guard seconds.isFinite, seconds > 0 else { return "" }
        return " · \(Int(seconds) / 60) 分钟" + (fullTracks.contains { $0.duration <= 0 } ? "（已知时长）" : "")
    }

    private var actionArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { playAllButton; Spacer(minLength: 0); actionIcons }
                VStack(alignment: .leading, spacing: 10) { playAllButton; actionIcons }
            }
            if let batch = model.nasDownloads.batches[source.key] {
                taskStatus(model.nasDownloads.submitting.contains(source.key) ? "正在提交到 NAS" : nasSummary(batch), icon: "externaldrive")
            }
            if let batch = model.collectionCache.batches[source.key] { taskStatus(batch.summary, icon: "iphone") }
        }
        .padding(.vertical, 4)
    }

    private var playAllButton: some View {
        Button("播放全部", systemImage: "play.fill") { Task { await model.playAll(fullTracks) } }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .labelStyle(.titleAndIcon)
            .frame(minHeight: 44)
            .disabled(!canAct)
            .accessibilityIdentifier("collection.playAll")
    }

    private var actionIcons: some View {
        HStack(spacing: 4) {
            if source.favoriteIdentity != nil {
                actionIcon(favorite ? "heart.fill" : "heart", title: favorite ? "取消收藏歌单" : "收藏歌单", id: "collection.favorite") {
                    if favorite { confirmingUnfavorite = true }
                    else { model.favoriteCollection(source, tracks: fullTracks) }
                }
                .foregroundStyle(favorite ? .orange : .primary)
                .disabled(!favorite && !canAct)
            }
            actionIcon("externaldrive.badge.plus", title: "下载到 NAS", id: "collection.nas") {
                sheet = model.nasDownloads.batches[source.key]?.submissionComplete == false ? .tasks : .nasOptions
            }
                .disabled(!canAct || model.sessionState == .offline)
            actionIcon("arrow.down.circle", title: "缓存到本机", id: "collection.cache") {
                if model.collectionCache.isCellular { confirmingCellular = true }
                else { startCache(allowsCellular: false) }
            }
            .disabled(!canAct)
        }
    }

    private func actionIcon(_ symbol: String, title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle())
        }
            .buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(id).help(title)
    }

    private func taskStatus(_ title: String, icon: String) -> some View {
        Button { sheet = .tasks } label: {
            HStack {
                Label(title, systemImage: icon).font(.caption)
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 30)
        }
        .buttonStyle(.plain)
    }

    private func nasSummary(_ batch: NASBatch) -> String {
        if batch.error != nil { return "NAS 下载需要重试" }
        let completed = batch.tasks.filter { $0.status == "completed" }.count
        return "NAS 已完成 \(completed)/\(batch.ids.count) · 跳过 \(batch.skipped) 首"
    }

    private func startCache(allowsCellular: Bool) {
        model.collectionCache.start(key: source.key, title: source.title, tracks: fullTracks, allowsCellular: allowsCellular)
    }

    private func load(force: Bool = false) async {
        guard !loading else { return }
        if case .playlist = source { complete = true; return }
        if tracks.isEmpty, let cached = model.cachedCompleteCollection(source), cached.tracks.count >= cached.total {
            tracks = cached.tracks
            complete = true
        }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let result = try await model.completeCollection(source, force: force)
            try Task.checkCancellation()
            tracks = result
            complete = true
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct CollectionSearchPresentation: ViewModifier {
    @Binding var query: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if isPresented {
            content.searchable(
                text: $query, isPresented: $isPresented,
                placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索此列表"
            )
        } else {
            content
        }
    }
}

struct NASDownloadOptions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: String
    let title: String
    let tracks: [MusicTrack]
    @State private var quality = NASQuality.mp3

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("目标", value: "NAS")
                    LabeledContent("列表", value: title)
                    LabeledContent("歌曲", value: "\(tracks.count) 首")
                    Picker("音质", selection: $quality) {
                        ForEach(NASQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Button("开始下载", systemImage: "arrow.down.to.line") {
                        model.nasDownloads.start(key: key, title: title, tracks: tracks, quality: quality)
                        dismiss()
                    }
                    .accessibilityIdentifier("collection.nas.confirm")
                }
            }
            .navigationTitle("下载到 NAS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct CollectionTasksSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let collectionKey: String

    var body: some View {
        NavigationStack {
            List {
                if let batch = model.collectionCache.batches[collectionKey] {
                    CacheTaskSection(batch: batch)
                }
                if let batch = model.nasDownloads.batches[collectionKey] {
                    NASTaskSection(batch: batch)
                }
                if let error = model.userDataSyncError {
                    Section("收藏同步") {
                        Text(error).foregroundStyle(.red)
                        Button("重试同步", systemImage: "arrow.clockwise") { Task { await model.retryUserDataSync() } }
                    }
                }
            }
            .navigationTitle("任务状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("关闭", systemImage: "xmark") { dismiss() } }
            }
            .task {
                while !Task.isCancelled {
                    await model.nasDownloads.refresh()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }
}

struct TrackDownloadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: MusicTrack
    @State private var confirmingCellular = false
    @State private var sheet: Sheet?
    private enum Sheet: String, Identifiable {
        case nas, tasks
        var id: Self { self }
    }
    private var key: String { "track:\(track.id)" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("歌曲", value: track.title)
                    LabeledContent("歌手", value: track.artist)
                }
                Section("下载到 NAS") {
                    Button("选择音质", systemImage: "externaldrive.badge.plus") { sheet = .nas }
                        .disabled(track.locator.kind == .local || model.sessionState == .offline)
                        .accessibilityIdentifier("download.nas")
                    if track.locator.kind == .local {
                        Label("已在 NAS 音乐库", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("缓存到手机") {
                    Button("缓存此歌曲", systemImage: "iphone.and.arrow.forward") {
                        if model.collectionCache.isCellular { confirmingCellular = true }
                        else { startCache(allowsCellular: false) }
                    }
                    .disabled(model.sessionState == .offline)
                    .accessibilityIdentifier("download.cache")
                    if let batch = model.collectionCache.batches[key] {
                        Text(batch.summary).foregroundStyle(.secondary)
                    }
                }
                if model.collectionCache.batches[key] != nil || model.nasDownloads.batches[key] != nil {
                    Section {
                        Button("任务状态", systemImage: "list.bullet") { sheet = .tasks }
                            .accessibilityIdentifier("download.tasks")
                    }
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $sheet) { value in
                switch value {
                case .nas: NASDownloadOptions(key: key, title: track.title, tracks: [track])
                case .tasks: CollectionTasksSheet(collectionKey: key)
                }
            }
            .confirmationDialog("使用蜂窝流量缓存此歌曲？", isPresented: $confirmingCellular, titleVisibility: .visible) {
                Button("使用蜂窝流量") { startCache(allowsCellular: true) }
                Button("等待 Wi-Fi") { startCache(allowsCellular: false) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func startCache(allowsCellular: Bool) {
        model.collectionCache.start(key: key, title: track.title, tracks: [track], allowsCellular: allowsCellular)
    }
}

private struct CacheTaskSection: View {
    @Environment(AppModel.self) private var model
    let batch: CollectionCacheBatch
    @State private var confirmingCellular = false

    var body: some View {
        Section("缓存到本机 · \(batch.summary)") {
            HStack {
                if !batch.cancelled, batch.paused || batch.items.contains(where: { $0.state == .failed || $0.state == .waitingWiFi }) {
                    Button("继续", systemImage: "play.fill") {
                        if model.collectionCache.isCellular { confirmingCellular = true }
                        else { model.collectionCache.resume(key: batch.key) }
                    }
                } else if !batch.isFinished, !batch.cancelled {
                    Button("暂停", systemImage: "pause") { model.collectionCache.pause(key: batch.key) }
                }
                Spacer()
                if !batch.isFinished, !batch.cancelled {
                    Button("取消", systemImage: "xmark", role: .destructive) { model.collectionCache.cancel(key: batch.key) }
                }
            }
            ForEach(batch.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.track.title).lineLimit(1)
                    Text(item.error ?? item.state.title)
                        .font(.caption)
                        .foregroundStyle(item.error == nil ? Color.secondary : Color.red)
                    if item.state == .downloading { ProgressView(value: item.progress) }
                }
            }
        }
        .confirmationDialog("允许此任务使用蜂窝流量？", isPresented: $confirmingCellular, titleVisibility: .visible) {
            Button("允许") { model.collectionCache.resume(key: batch.key, allowsCellular: true) }
        }
    }
}

private struct NASTaskSection: View {
    @Environment(AppModel.self) private var model
    let batch: NASBatch
    var body: some View {
        Section("下载到 NAS · 跳过 \(batch.skipped) 首") {
            if let error = batch.error {
                Text(error).font(.footnote).foregroundStyle(.red)
                Button("重试", systemImage: "arrow.clockwise") {
                    if batch.submissionComplete { Task { await model.nasDownloads.refresh() } }
                    else { model.nasDownloads.retry(key: batch.collectionKey) }
                }
            }
            Text("已提交 \(batch.ids.count) 首").font(.subheadline)
            ForEach(batch.tasks) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).lineLimit(1)
                    Text(item.error ?? item.statusTitle).font(.caption).foregroundStyle(.secondary)
                    if item.status == "downloading" { ProgressView(value: item.progress) }
                }
            }
        }
    }
}
