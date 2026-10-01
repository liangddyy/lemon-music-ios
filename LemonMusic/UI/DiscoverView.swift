// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct DiscoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 26) {
                sourcePicker

                if !model.discoverAlbums.isEmpty {
                    VStack(spacing: 12) {
                        SectionTitle(title: "新碟")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(model.discoverAlbums) { album in
                                    VStack(alignment: .leading, spacing: 8) {
                                        AlbumArtwork(album: album, size: 145)
                                        Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(width: 145, alignment: .leading)
                                }
                            }
                        }
                    }
                }

                if !model.toplists.isEmpty {
                    VStack(spacing: 12) {
                        SectionTitle(title: "排行榜")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(model.toplists) { list in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Image(systemName: "chart.bar.fill")
                                            .font(.title)
                                            .foregroundStyle(.orange)
                                        Text(list.name)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(2)
                                    }
                                    .padding(16)
                                    .frame(width: 150, height: 110, alignment: .leading)
                                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
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
                } else if !model.isRefreshing {
                    EmptyContentView(title: "暂无发现内容", systemImage: "sparkles", message: "请确认服务端已启用当前音源")
                        .frame(minHeight: 280)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 100)
        }
        .navigationTitle("发现")
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

