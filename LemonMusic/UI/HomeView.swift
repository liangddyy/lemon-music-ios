// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 26) {
                welcomeHeader

                if !model.recentTracks.isEmpty {
                    trackCarousel(title: "最近播放", tracks: Array(model.recentTracks.prefix(12)))
                }
                if !model.recentlyAdded.isEmpty {
                    trackCarousel(title: "最近添加", tracks: Array(model.recentlyAdded.prefix(12)))
                }
                if !model.userData.favorites.isEmpty {
                    trackSection(title: "我的收藏", tracks: Array(model.userData.favorites.prefix(8)))
                }
                if !model.userData.playlists.isEmpty {
                    playlistSection
                }
                if model.tracks.isEmpty {
                    EmptyContentView(title: "音乐库还是空的", systemImage: "music.note.house", message: "请先在 Lemon Music 服务端扫描音乐库")
                        .frame(minHeight: 300)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 100)
        }
        .navigationTitle("首页")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("设置", systemImage: "gearshape") { showingSettings = true }
            }
        }
        .refreshable { await model.refreshAll(force: true) }
        .sheet(isPresented: $showingSettings) { NavigationStack { SettingsView() } }
    }

    private var welcomeHeader: some View {
        HStack(spacing: 14) {
            LemonMark(size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.profile?.user?.displayName ?? "欢迎回来")
                    .font(.title2.weight(.bold))
                Text("今天想听点什么？")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                guard let track = model.tracks.randomElement() else { return }
                Task { await model.play(track, in: model.tracks.shuffled()) }
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(.orange)
            .disabled(model.tracks.isEmpty)
        }
        .padding(.top, 4)
    }

    private func trackCarousel(title: String, tracks: [MusicTrack]) -> some View {
        VStack(spacing: 12) {
            SectionTitle(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(tracks) { track in
                        Button {
                            Task { await model.play(track, in: tracks) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                TrackArtwork(track: track, size: 138)
                                Text(track.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 138, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func trackSection(title: String, tracks: [MusicTrack]) -> some View {
        VStack(spacing: 12) {
            SectionTitle(title: title)
            ForEach(tracks) { TrackRow(track: $0, queue: tracks) }
        }
    }

    private var playlistSection: some View {
        VStack(spacing: 12) {
            SectionTitle(title: "我的歌单")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(model.userData.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.14))
                                    Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.orange)
                                }
                                .frame(width: 140, height: 140)
                                Text(playlist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(playlist.tracks.count) 首").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 140, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: MusicPlaylist

    var body: some View {
        List {
            if playlist.tracks.isEmpty {
                EmptyContentView(title: "歌单为空", systemImage: "music.note.list", message: "从歌曲菜单中添加音乐")
            } else {
                ForEach(playlist.tracks) { TrackRow(track: $0, queue: playlist.tracks) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        .toolbar {
            if let first = playlist.tracks.first {
                Button("播放", systemImage: "play.fill") { Task { await model.play(first, in: playlist.tracks) } }
            }
        }
    }
}

