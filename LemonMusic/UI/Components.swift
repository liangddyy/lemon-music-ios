// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI
import UIKit

struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let track: MusicTrack
    var queue: [MusicTrack]? = nil

    var body: some View {
        Button {
            Task { await model.play(track, in: queue) }
        } label: {
            HStack(spacing: 12) {
                TrackArtwork(track: track, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.favoriteIDs.contains(track.id) {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Menu {
                    Button(model.favoriteIDs.contains(track.id) ? "取消收藏" : "收藏", systemImage: "heart") {
                        model.toggleFavorite(track)
                    }
                    Button("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        model.playback.playNext(track)
                    }
                    Menu("添加到歌单", systemImage: "text.badge.plus") {
                        ForEach(model.userData.playlists) { playlist in
                            Button(playlist.name) { model.add(track, to: playlist.id) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 36)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TrackArtwork: View {
    @Environment(AppModel.self) private var model
    let track: MusicTrack
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(9, size * 0.18), style: .continuous)
                .fill(Color(.tertiarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: min(9, size * 0.18), style: .continuous))
        .task(id: track.id) { image = await model.artworkStore.image(for: track, api: model.api) }
    }
}

struct AlbumArtwork: View {
    let album: MusicAlbum
    let size: CGFloat

    var body: some View {
        AsyncImage(url: album.artworkURL.flatMap(URL.init(string:))) { phase in
            if let image = phase.image { image.resizable().scaledToFill() }
            else {
                ZStack {
                    Color(.tertiarySystemFill)
                    Image(systemName: "square.stack.fill").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct EmptyContentView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

