// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct DiscoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: model.compactDisplay ? 18 : 26) {
                sourcePicker
                if model.isRefreshingDiscover {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let error = model.discoverError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !model.toplists.isEmpty {
                    VStack(spacing: 12) {
                        SectionTitle(title: "排行榜")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(model.toplists) { list in
                                    NavigationLink {
                                        OnlineCollectionView(collection: OnlineCollection(
                                            kind: .toplist, source: model.selectedSourceID, id: list.providerID,
                                            title: list.name, artworkURL: list.artworkURL
                                        ))
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            PlaylistArtwork(playlist: list, size: 145)
                                            Text(list.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        }
                                        .frame(width: 145, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                if !model.discoverPlaylists.isEmpty {
                    VStack(spacing: 12) {
                        SectionTitle(title: "推荐歌单")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(model.discoverPlaylists) { playlist in
                                    NavigationLink {
                                        OnlineCollectionView(collection: OnlineCollection(
                                            kind: .playlist, source: model.selectedSourceID,
                                            id: playlist.providerID, title: playlist.name, artworkURL: playlist.artworkURL
                                        ))
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            PlaylistArtwork(playlist: playlist, size: 145)
                                            Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        }
                                        .frame(width: 145, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                if !model.discoverSongs.isEmpty {
                    VStack(spacing: 12) {
                        SectionTitle(title: "新歌")
                        ForEach(model.discoverSongs.prefix(20)) { TrackRow(track: $0, queue: model.discoverSongs) }
                    }
                } else if !model.isRefreshingDiscover, model.toplists.isEmpty, model.discoverPlaylists.isEmpty {
                    EmptyContentView(title: "暂无发现内容", systemImage: "sparkles", message: "请确认服务端已启用当前音源")
                        .frame(minHeight: 280)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 100)
        }
        .scrollBounceBehavior(.always)
        .navigationTitle("发现")
        .navigationBarTitleDisplayMode(model.compactDisplay ? .inline : .large)
        .task { await model.refreshDiscover() }
        .refreshable { await model.refreshDiscover(force: true) }
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.sources) { source in
                    Button(source.name) { Task { await model.selectSource(source.id) } }
                        .buttonStyle(.borderedProminent)
                        .tint(model.selectedSourceID == source.id ? .orange : Color(.tertiarySystemFill))
                        .foregroundStyle(model.selectedSourceID == source.id ? .white : .primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
