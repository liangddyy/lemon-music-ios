// Derived from Cassette, licensed under MPL-2.0.

import SwiftUI

enum MiniPlayerPresentation {
    case legacy
    case expandedAccessory
    case inlineAccessory
}

struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingPlayer: Bool
    let presentation: MiniPlayerPresentation

    var body: some View {
        if let track = model.playback.currentTrack {
            player(track)
        }
    }

    @ViewBuilder
    private func player(_ track: MusicTrack) -> some View {
        let isInline = presentation == .inlineAccessory
        let artworkSize: CGFloat = isInline ? 30 : (presentation == .expandedAccessory ? 40 : 44)

        let content = HStack(spacing: isInline ? 8 : 12) {
            Button { showingPlayer = true } label: {
                HStack(spacing: isInline ? 8 : 12) {
                    TrackArtwork(track: track, size: artworkSize)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(isInline ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !isInline {
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)

            Button { model.playback.togglePlayPause() } label: {
                Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(isInline ? .body : .title3)
                    .frame(width: isInline ? 32 : 38, height: isInline ? 32 : 38)
            }
            .accessibilityLabel(model.playback.isPlaying ? "暂停" : "播放")

            if !isInline {
                Button { Task { await model.playback.next() } } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 34, height: 38)
                }
                .accessibilityLabel("下一首")
            }
        }

        if presentation == .legacy {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        } else {
            content
                .padding(.horizontal, isInline ? 8 : 14)
                .padding(.vertical, isInline ? 2 : 5)
        }
    }
}

struct FullPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingLyrics = false
    @State private var showingQueue = false
    @State private var lyricDocument = LyricDocument.empty
    @State private var lyricsLoading = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let artworkSize = min(proxy.size.width - 44, max(180, proxy.size.height * 0.43), 420)
                if let track = model.playback.currentTrack {
                    VStack(spacing: 0) {
                        Group {
                            if showingLyrics {
                                PlayerLyricsView(
                                    document: lyricDocument,
                                    loading: lyricsLoading,
                                    position: model.playback.position,
                                    size: artworkSize
                                ) {
                                    withAnimation(.snappy(duration: 0.32)) { showingLyrics = false }
                                }
                                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            } else {
                                TrackArtwork(track: track, size: artworkSize)
                                    .shadow(color: .black.opacity(0.24), radius: 28, y: 16)
                                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .onTapGesture {
                                        withAnimation(.snappy(duration: 0.32)) { showingLyrics = true }
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel("显示歌词")
                                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            }
                        }

                        Spacer(minLength: 10)

                        VStack(spacing: 5) {
                            Text(track.title)
                                .font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            Text(track.artist)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !track.album.isEmpty {
                                Text(track.album)
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 10)
                        progress
                        Spacer(minLength: 10)
                        controls
                        Spacer(minLength: 10)
                        secondaryControls(track)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
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
            .sheet(isPresented: $showingQueue) { QueueSheet() }
            .task(id: model.playback.currentTrack?.id) {
                await loadLyrics(for: model.playback.currentTrack)
            }
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
            PlayerIconButton(
                icon: model.favoriteIDs.contains(track.id) ? "heart.fill" : "heart",
                label: model.favoriteIDs.contains(track.id) ? "取消收藏" : "收藏"
            ) {
                model.toggleFavorite(track)
            }
            Spacer()
            PlayerIconButton(icon: showingLyrics ? "photo" : "quote.bubble", label: showingLyrics ? "显示封面" : "显示歌词") {
                withAnimation(.snappy(duration: 0.32)) { showingLyrics.toggle() }
            }
            Spacer()
            PlayerIconButton(
                icon: model.playback.isShuffled ? "shuffle.circle.fill" : "shuffle",
                label: model.playback.isShuffled ? "关闭随机播放" : "随机播放"
            ) {
                model.playback.toggleShuffle()
            }
            Spacer()
            PlayerIconButton(icon: "list.bullet", label: "播放队列") { showingQueue = true }
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

    private func loadLyrics(for track: MusicTrack?) async {
        lyricDocument = .empty
        guard let track else {
            lyricsLoading = false
            return
        }
        lyricsLoading = true
        let value = await model.lyrics(for: track)
        guard !Task.isCancelled, model.playback.currentTrack?.id == track.id else { return }
        lyricDocument = LyricDocument(rawValue: value)
        lyricsLoading = false
    }
}

private struct PlayerIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .frame(width: 46, height: 46)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct PlayerLyricsView: View {
    let document: LyricDocument
    let loading: Bool
    let position: TimeInterval
    let size: CGFloat
    let onTap: () -> Void

    private var activeLineID: Int? {
        document.currentLineIndex(at: position).map { document.lines[$0].id }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
            Color.orange.opacity(0.06)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if loading {
                ProgressView()
                    .tint(.orange)
            } else if document.lines.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("暂无歌词")
                        .font(.headline)
                    Text("当前歌曲没有可用歌词")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            Spacer().frame(height: size * 0.34)
                            ForEach(Array(document.lines.enumerated()), id: \.element.id) { index, line in
                                let isActive = line.id == activeLineID
                                Text(line.text)
                                    .font(isActive ? .title2.weight(.bold) : .title3.weight(.semibold))
                                    .foregroundStyle(isActive ? Color.primary : Color.secondary.opacity(lineOpacity(at: index)))
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(5)
                                    .frame(maxWidth: .infinity)
                                    .scaleEffect(isActive ? 1 : 0.96)
                                    .animation(.easeInOut(duration: 0.25), value: activeLineID)
                                    .id(line.id)
                            }
                            Spacer().frame(height: size * 0.34)
                        }
                        .padding(.horizontal, 18)
                    }
                    .scrollIndicators(.hidden)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.13),
                                .init(color: .black, location: 0.87),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .onChange(of: activeLineID, initial: true) { _, newValue in
                        guard let newValue else { return }
                        withAnimation(.easeInOut(duration: 0.35)) {
                            reader.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("显示封面")
    }

    private func lineOpacity(at index: Int) -> Double {
        guard let activeIndex = document.currentLineIndex(at: position) else { return 0.82 }
        let distance = abs(index - activeIndex)
        return distance <= 1 ? 0.72 : (distance <= 3 ? 0.48 : 0.3)
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
