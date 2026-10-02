// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var section: Section = .songs

    private enum Section: String, CaseIterable, Identifiable {
        case songs = "歌曲"
        case albums = "专辑"
        case artists = "歌手"
        case playlists = "歌单"
        case genres = "流派"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("分类", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            content
        }
        .navigationTitle("音乐库")
        .refreshable { await model.refreshAll(force: true) }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .songs:
            List(model.tracks) { TrackRow(track: $0, queue: model.tracks) }
                .listStyle(.plain)
        case .albums:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 22) {
                    ForEach(model.albums) { album in
                        NavigationLink {
                            CollectionDetailView(source: .local(LocalCollection(
                                kind: .album, value: album.title, artist: album.artist, artworkURL: album.artworkURL,
                                artworkCacheKey: "album:\(album.id)"
                            )))
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                AlbumArtwork(album: album, size: 160)
                                    .frame(maxWidth: .infinity)
                                Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .padding(.bottom, 90)
            }
        case .artists:
            List(model.artists) { artist in
                NavigationLink {
                    CollectionDetailView(source: .local(LocalCollection(kind: .artist, value: artist.name)))
                } label: {
                    Label(artist.name, systemImage: "person.crop.circle.fill")
                }
            }
            .listStyle(.plain)
        case .playlists:
            List(model.userData.playlists) { playlist in
                NavigationLink(value: playlist.id) {
                    Label {
                        VStack(alignment: .leading) {
                            Text(playlist.name)
                            Text("\(playlist.tracks.count) 首").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "music.note.list") }
                }
            }
            .listStyle(.plain)
            .navigationDestination(for: String.self) { id in
                if let playlist = model.userData.playlists.first(where: { $0.id == id }) { PlaylistDetailView(playlist: playlist) }
            }
        case .genres:
            List(model.genres, id: \.self) { genre in
                NavigationLink {
                    CollectionDetailView(source: .local(LocalCollection(kind: .genre, value: genre)))
                } label: {
                    Label(genre, systemImage: "guitars.fill")
                }
            }
            .listStyle(.plain)
        }
    }
}
