// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingPlayer: Bool

    var body: some View {
        if let track = model.playback.currentTrack {
            HStack(spacing: 12) {
                Button { showingPlayer = true } label: {
                    HStack(spacing: 12) {
                        TrackArtwork(track: track, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                Button { model.playback.togglePlayPause() } label: {
                    Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 38, height: 38)
                }
                Button { Task { await model.playback.next() } } label: {
                    Image(systemName: "forward.fill").frame(width: 34, height: 38)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }
}

struct FullPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingLyrics = false
    @State private var showingQueue = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let artworkSize = min(proxy.size.width - 44, 420)
                ScrollView {
                    VStack(spacing: 28) {
                        if let track = model.playback.currentTrack {
                            TrackArtwork(track: track, size: artworkSize)
                                .shadow(color: .black.opacity(0.24), radius: 28, y: 16)
                                .padding(.top, 20)

                            VStack(spacing: 7) {
                                Text(track.title)
                                    .font(.title2.weight(.bold))
                                    .multilineTextAlignment(.center)
                                Text(track.artist)
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                if !track.album.isEmpty {
                                    Text(track.album).font(.subheadline).foregroundStyle(.tertiary)
                                }
                            }

                            progress
                            controls
                            secondaryControls(track)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 40)
                }
            }
            .background(playerBackground)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "chevron.down") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text("正在播放").font(.subheadline.weight(.semibold))
                }
            }
            .sheet(isPresented: $showingLyrics) { LyricsSheet() }
            .sheet(isPresented: $showingQueue) { QueueSheet() }
        }
    }

    private var progress: some View {
        VStack(spacing: 7) {
            Slider(value: Binding(
                get: { min(model.playback.position, max(model.playback.duration, 1)) },
                set: { model.playback.seek(to: $0) }
            ), in: 0...max(model.playback.duration, 1))
            .tint(.primary)
            HStack {
                Text(time(model.playback.position))
                Spacer()
                Text("-" + time(max(0, model.playback.duration - model.playback.position)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { Task { await model.playback.previous() } } label: {
                Image(systemName: "backward.fill").font(.system(size: 30))
            }
            Button { model.playback.togglePlayPause() } label: {
                Image(systemName: model.playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
            }
            Button { Task { await model.playback.next() } } label: {
                Image(systemName: "forward.fill").font(.system(size: 30))
            }
        }
        .buttonStyle(.plain)
    }

    private func secondaryControls(_ track: MusicTrack) -> some View {
        HStack {
            PlayerIconButton(icon: model.favoriteIDs.contains(track.id) ? "heart.fill" : "heart") {
                model.toggleFavorite(track)
            }
            Spacer()
            PlayerIconButton(icon: "quote.bubble") { showingLyrics = true }
            Spacer()
            PlayerIconButton(icon: model.playback.isShuffled ? "shuffle.circle.fill" : "shuffle") {
                model.playback.toggleShuffle()
            }
            Spacer()
            PlayerIconButton(icon: "list.bullet") { showingQueue = true }
        }
        .foregroundStyle(.primary)
    }

    private var playerBackground: some View {
        LinearGradient(
            colors: [Color.orange.opacity(0.18), Color(.systemBackground), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct PlayerIconButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .frame(width: 46, height: 46)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct LyricsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var lyrics = ""
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView().padding(.top, 80)
                } else if lyrics.isEmpty {
                    EmptyContentView(title: "暂无歌词", systemImage: "quote.bubble", message: "当前歌曲没有可用歌词")
                        .frame(minHeight: 360)
                } else {
                    Text(cleanLyrics(lyrics))
                        .font(.title3.weight(.medium))
                        .lineSpacing(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                }
            }
            .navigationTitle("歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .task {
                if let track = model.playback.currentTrack { lyrics = await model.lyrics(for: track) }
                loading = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func cleanLyrics(_ value: String) -> String {
        value
            .split(separator: "\n")
            .map { line in line.replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }
}

private struct QueueSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(model.playback.queue.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 12) {
                        TrackArtwork(track: track, size: 42)
                        VStack(alignment: .leading) {
                            Text(track.title).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if index == model.playback.currentIndex {
                            Image(systemName: "waveform").foregroundStyle(.orange)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await model.play(track, in: model.playback.queue) } }
                }
                .onDelete(perform: model.playback.removeFromQueue)
                .onMove(perform: model.playback.moveQueue)
            }
            .navigationTitle("播放队列")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

