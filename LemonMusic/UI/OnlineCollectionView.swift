import SwiftUI

struct OnlineCollectionView: View {
    @Environment(AppModel.self) private var model
    let collection: OnlineCollection
    @State private var tracks: [MusicTrack] = []
    @State private var page = 0
    @State private var total = 0
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(tracks) { track in TrackRow(track: track, queue: tracks) }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
                Button("重试") { Task { await load(reset: page == 0, force: true) } }
            }
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else if tracks.isEmpty, errorMessage == nil {
                EmptyContentView(title: "暂无歌曲", systemImage: "music.note.list", message: "当前列表没有可用歌曲")
            } else if tracks.count < total, collection.kind != .playlist {
                Button("加载更多") { Task { await load(reset: false) } }
            }
        }
        .listStyle(.plain)
        .navigationTitle(collection.title)
        .toolbar {
            if let first = tracks.first {
                Button("播放", systemImage: "play.fill") { Task { await model.play(first, in: tracks) } }
            }
        }
        .task {
            if page == 0 {
                if let cached = model.cachedCollectionPage(collection) {
                    tracks = cached.tracks
                    total = cached.total
                }
                await load(reset: true)
            }
        }
        .refreshable { await load(reset: true, force: true) }
    }

    private func load(reset: Bool, force: Bool = false) async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let nextPage = reset ? 1 : page + 1
            let result = try await model.collectionTracks(collection, page: nextPage, force: force)
            if reset { tracks = [] }
            var seen = Set(tracks.map(\.id))
            tracks.append(contentsOf: result.tracks.filter { seen.insert($0.id).inserted })
            total = result.tracks.isEmpty ? tracks.count : result.total
            page = nextPage
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
