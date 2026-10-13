// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var scope: Scope = .online
    @State private var searchTask: Task<Void, Never>?
    @State private var onlineKind: OnlineSearchKind = .songs

    private enum Scope: String, CaseIterable, Identifiable { case local = "音乐库", online = "在线"; var id: Self { self } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("范围", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if scope == .online {
                sourcePicker
                Picker("在线分类", selection: $onlineKind) {
                    ForEach(OnlineSearchKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            results
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(model.compactDisplay ? .inline : .large)
        .searchable(text: $query, prompt: scope == .local ? "搜索本地歌曲、歌手或专辑" : "搜索在线音乐")
        .onChange(of: query) { _, value in scheduleSearch(value) }
        .onAppear { scope = Scope(rawValue: model.preferredSearchScope) ?? .online }
        .onChange(of: scope) { _, value in
            model.preferredSearchScope = value.rawValue
            scheduleSearch(query)
        }
        .onChange(of: onlineKind) { _, _ in scheduleSearch(query) }
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.sources) { source in
                    Button(source.name) {
                        searchTask?.cancel()
                        searchTask = Task {
                            await model.selectSource(source.id, refreshDiscovery: false)
                            await model.searchOnline(query, kind: onlineKind)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(model.selectedSourceID == source.id ? .orange : .secondary)
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var results: some View {
        let tracks = scope == .local ? model.localSearch(query) : model.onlineSearchResults
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyContentView(title: "搜索音乐", systemImage: "magnifyingglass", message: "输入歌曲、歌手或专辑名称")
        } else if model.isSearching {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scope == .online, onlineKind != .songs {
            collectionResults
        } else if tracks.isEmpty {
            EmptyContentView(title: "没有找到结果", systemImage: "music.note", message: "换个关键词或音源试试")
        } else {
            List(tracks) { TrackRow(track: $0, queue: tracks) }
                .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var collectionResults: some View {
        if onlineKind == .albums {
            List(model.onlineSearchAlbums) { album in
                NavigationLink {
                    OnlineCollectionView(collection: OnlineCollection(
                        kind: .album, source: album.sourceID, id: album.providerID, title: album.title,
                        artworkURL: album.artworkURL
                    ))
                } label: {
                    HStack(spacing: 12) {
                        AlbumArtwork(album: album, size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(album.title).lineLimit(1)
                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.onlineSearchAlbums.isEmpty {
                    EmptyContentView(title: "没有找到专辑", systemImage: "square.stack", message: "换个关键词或音源试试")
                }
            }
        } else {
            List(model.onlineSearchPlaylists) { playlist in
                NavigationLink {
                    OnlineCollectionView(collection: OnlineCollection(
                        kind: .playlist, source: model.selectedSourceID, id: playlist.providerID, title: playlist.name,
                        artworkURL: playlist.artworkURL
                    ))
                } label: {
                    HStack(spacing: 12) {
                        PlaylistArtwork(playlist: playlist, size: 48)
                        Text(playlist.name).lineLimit(2)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.onlineSearchPlaylists.isEmpty {
                    EmptyContentView(title: "没有找到歌单", systemImage: "music.note.list", message: "换个关键词或音源试试")
                }
            }
        }
    }

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        guard scope == .online else { return }
        let kind = onlineKind
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.searchOnline(value, kind: kind)
        }
    }
}
