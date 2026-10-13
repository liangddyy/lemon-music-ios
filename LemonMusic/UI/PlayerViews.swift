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
            .accessibilityIdentifier("miniPlayer.open")

            Button { model.playback.togglePlayPause() } label: {
                Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(isInline ? .body : .title3)
                    .frame(width: isInline ? 32 : 38, height: isInline ? 32 : 38)
            }
            .accessibilityLabel(model.playback.isPlaying ? "暂停" : "播放")
            .disabled(model.playback.isLoadingTrack)

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingLyrics = false
    @State private var showingQueue = false
    @State private var downloadTrack: MusicTrack?
    @State private var lyricDocument = LyricDocument.empty
    @State private var lyricsLoading = false
    @State private var dismissProgress: CGFloat = 0
    @State private var isDismissing = false
    @State private var isSeeking = false
    @State private var seekPosition: TimeInterval = 0
    @State private var dismissGestureAccepted = false
    @State private var progressFrame = CGRect.zero

    var body: some View {
        GeometryReader { presentation in
        NavigationStack {
            GeometryReader { proxy in
                let artworkSize = max(1, min(proxy.size.width - 44, max(168, proxy.size.height * 0.39), 400))
                if let track = model.playback.currentTrack {
                    VStack(spacing: 0) {
                        ZStack {
                        if showingLyrics {
                            PlayerLyricsView(
                                document: lyricDocument,
                                loading: lyricsLoading,
                                position: model.playback.position
                            ) {
                                withAnimation(.snappy(duration: 0.32)) { showingLyrics = false }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                        } else {
                            VStack(spacing: 0) {
                                TrackArtwork(track: track, size: artworkSize)
                                    .shadow(color: .black.opacity(0.24), radius: 28, y: 16)
                                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .onTapGesture {
                                        withAnimation(.snappy(duration: 0.32)) { showingLyrics = true }
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel("显示歌词")
                                    .transition(.opacity.combined(with: .scale(scale: 0.98)))

                                Spacer(minLength: 10)

                                VStack(spacing: 5) {
                                    Text(track.title)
                                        .font(model.compactDisplay ? .title3.weight(.bold) : .title2.weight(.bold))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                    Text(track.artist)
                                        .font(model.compactDisplay ? .subheadline : .title3)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if !track.album.isEmpty {
                                        Text(track.album)
                                            .font(.subheadline)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    playbackStatus(track)
                                        .accessibilityIdentifier("player.cacheStatus")
                                }
                                .accessibilityIdentifier("player.trackInfo")

                                Spacer(minLength: 10)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                        }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(showingLyrics ? "player.lyrics" : "player.media")
                        .accessibilityAction(named: showingLyrics ? "显示封面" : "显示歌词") {
                            withAnimation(.snappy(duration: 0.32)) { showingLyrics.toggle() }
                        }
                        .simultaneousGesture(mediaSwitchGesture)

                        Spacer().frame(height: 10)
                        progress
                        Spacer().frame(height: 14)
                        controls
                        Spacer().frame(height: 14)
                        secondaryControls(track)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .modifier(AccessiblePlayerScroll(enabled: dynamicTypeSize.isAccessibilitySize && !showingLyrics))
                }
            }
            .background(playerBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "chevron.down") { closePlayer() }
                        .accessibilityIdentifier("player.close")
                }
                ToolbarItem(placement: .principal) {
                    Text("正在播放").font(.subheadline.weight(.semibold))
                }
            }
            .sheet(isPresented: $showingQueue) { QueueSheet() }
            .sheet(item: $downloadTrack) { TrackDownloadSheet(track: $0) }
            .task(id: model.playback.currentTrack?.id) {
                await loadLyrics(for: model.playback.currentTrack)
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .offset(y: reduceMotion ? 0 : dismissProgress * presentation.size.height)
        .opacity(reduceMotion ? 1 - dismissProgress : 1)
        .simultaneousGesture(edgeDismissGesture(width: presentation.size.width))
        .accessibilityIdentifier("player.surface")
        }
        .presentationBackground(.clear)
    }

    private var progress: some View {
        VStack(spacing: 7) {
            Slider(value: Binding(
                get: { min(isSeeking ? seekPosition : model.playback.position, max(model.playback.duration, 1)) },
                set: {
                    seekPosition = $0
                    if !isSeeking { model.playback.seek(to: $0) }
                }
            ), in: 0...max(model.playback.duration, 1), onEditingChanged: { editing in
                if editing { seekPosition = model.playback.position }
                else { model.playback.seek(to: seekPosition) }
                isSeeking = editing
            })
            .tint(.primary)
            .accessibilityIdentifier("player.progress")
            .disabled(!model.playback.canSeek)
            HStack {
                Text(time(model.playback.position))
                Spacer()
                Text("-" + time(max(0, model.playback.duration - model.playback.position)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if model.playback.isAudioInterrupted {
                Text("播放已被其他音频暂停")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("player.interrupted")
            }
            if model.playback.isLoadingTrack || model.playback.isBuffering {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.playback.isLoadingTrack ? "正在加载音频" : "正在缓冲音频").font(.caption)
                }
                .accessibilityIdentifier("player.loading")
            }
            if let error = model.playback.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("重试", systemImage: "arrow.clockwise") { model.playback.resume() }
                        .font(.caption)
                        .accessibilityIdentifier("player.retry")
                }
                .accessibilityIdentifier("player.error")
            }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { progressFrame = $0 }
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
            .disabled(model.playback.isLoadingTrack || model.playback.isAudioInterrupted)
            .accessibilityIdentifier("player.playPause")
            .accessibilityLabel(model.playback.isPlaying ? "暂停" : "播放")
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
            PlayerIconButton(icon: "arrow.down.to.line", label: "下载") {
                downloadTrack = track
            }
            .accessibilityIdentifier("player.download")
            Spacer()
            PlayerIconButton(
                icon: model.playback.mode.symbol,
                label: model.playback.mode.title
            ) {
                model.playback.cycleMode()
            }
            .accessibilityIdentifier("player.mode")
            .accessibilityValue(model.playback.mode.title)
            Spacer()
            PlayerIconButton(icon: "list.bullet", label: "播放队列") { showingQueue = true }
        }
        .foregroundStyle(.primary)
    }

    private func playbackStatus(_ track: MusicTrack) -> some View {
        HStack(spacing: 7) {
            PlaybackStatusBadge(
                title: sourceTitle(for: track),
                icon: track.locator.kind == .local ? "externaldrive.fill" : "globe",
                color: .secondary
            )

            switch model.playback.audioCacheState(for: track) {
            case .notCached:
                PlaybackStatusBadge(
                    title: model.audioCache.automaticCachingEnabled ? "未缓存" : "自动缓存已关闭",
                    icon: "icloud.and.arrow.down", color: .secondary
                )
            case .caching(let progress):
                let title = progress.map { "已缓存 \(Int($0 * 100))%" } ?? "边播边缓存"
                PlaybackStatusBadge(title: title, icon: "arrow.down.circle", color: .orange)
            case .cached:
                PlaybackStatusBadge(title: "已缓存", icon: "checkmark.circle.fill", color: .green)
            case .failed:
                PlaybackStatusBadge(title: "缓存失败", icon: "exclamationmark.triangle.fill", color: .red)
            }
        }
        .padding(.top, 2)
    }

    private func sourceTitle(for track: MusicTrack) -> String {
        guard track.locator.kind == .online else { return "服务器本地歌曲" }
        guard let sourceID = track.locator.source,
              let sourceName = model.sources.first(where: { $0.id == sourceID })?.name else { return "在线歌曲" }
        return "在线歌曲 · \(sourceName)"
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

    private func edgeDismissGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !showingQueue, !isDismissing, !isSeeking, value.startLocation.x <= 22,
                      value.translation.width > 0,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                if !dismissGestureAccepted,
                   progressFrame.insetBy(dx: -24, dy: -12).contains(value.startLocation) { return }
                dismissGestureAccepted = true
                dismissProgress = min(1, value.translation.width / max(1, width))
            }
            .onEnded { value in
                defer { dismissGestureAccepted = false }
                let isEdgeSwipe = value.startLocation.x <= 22
                    && value.translation.width > 0
                    && abs(value.translation.width) > abs(value.translation.height)
                let shouldDismiss = dismissGestureAccepted && !showingQueue && isEdgeSwipe
                    && max(value.translation.width, value.predictedEndTranslation.width) > width / 3
                if shouldDismiss {
                    closePlayer()
                } else {
                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.86)) {
                        dismissProgress = 0
                    }
                }
            }
    }

    private var mediaSwitchGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onEnded { value in
                guard value.startLocation.x > 22, !isDismissing, !showingQueue,
                      abs(value.translation.width) > 50,
                      abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                withAnimation(.snappy(duration: 0.32)) { showingLyrics = value.translation.width < 0 }
            }
    }

    private func closePlayer() {
        guard !isDismissing else { return }
        isDismissing = true
        withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.25), completionCriteria: .removed) {
            dismissProgress = 1
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
}

private struct AccessiblePlayerScroll: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { ScrollView { content }.scrollBounceBehavior(.basedOnSize) }
        else { content }
    }
}

private struct PlayerIconButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .id(icon)
                .symbolRenderingMode(.monochrome)
                .font(.title3.weight(.semibold))
                .frame(width: 46, height: 46)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct PlaybackStatusBadge: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
    }
}

private struct PlayerLyricsView: View {
    let document: LyricDocument
    let loading: Bool
    let position: TimeInterval
    let onTap: () -> Void

    private var activeLineID: Int? {
        document.currentLineIndex(at: position).map { document.lines[$0].id }
    }

    var body: some View {
        GeometryReader { geometry in
        ZStack {
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
                            Spacer().frame(height: geometry.size.height / 2)
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
                            Spacer().frame(height: geometry.size.height / 2)
                        }
                        .padding(.horizontal, 4)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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
