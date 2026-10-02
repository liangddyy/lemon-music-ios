// Derived from Cassette, licensed under MPL-2.0.

import AudioStreaming
import AVFAudio
import Foundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit
import OSLog

@Observable
@MainActor
final class PlaybackController {
    static let audioSessionCategory: AVAudioSession.Category = .playback
    static let audioSessionMode: AVAudioSession.Mode = .default
    // Playback permits AirPlay implicitly; allowAirPlay is valid only for playAndRecord.
    static let audioSessionOptions: AVAudioSession.CategoryOptions = []
    enum AudioCacheState: Equatable {
        case notCached
        case caching(Double?)
        case cached
        case failed
    }

    private(set) var currentTrack: MusicTrack?
    private var queueState = PlaybackQueue()
    var queue: [MusicTrack] { queueState.tracks }
    var currentIndex: Int { queueState.index }
    var mode: PlaybackMode { queueState.mode }
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var audioCacheStates: [String: AudioCacheState] = [:]
    var lastError: String?
    var showingFullPlayer = false
    var preferredTrack: ((MusicTrack) async -> MusicTrack)?
    var willPlayTrack: ((MusicTrack) async -> Void)?
    var onTrackChanged: (() -> Void)?

    private nonisolated(unsafe) let player: AudioPlayer
    private let playerDelegate: LemonAudioPlayerDelegate
    private let api: LemonAPIClient
    private let audioCache: AudioCache
    private let artworkStore: ArtworkStore
    private let defaults: UserDefaults
    private let audioPolicy: AudioPlaybackPolicy?
    private let startupTimeout: Duration
    private let logger = Logger(subsystem: "top.btop.music", category: "Playback")
    private var progressTask: Task<Void, Never>?
    private var retryingCurrentItem = false
    private var currentPlaybackUsesCache = false
    private var currentPlaybackUsesPartialCache = false
    private var playbackRequest = PlaybackRequestState()
    private(set) var isLoadingTrack = false
    private(set) var isBuffering = false
    private var engineHasEntry = false
    private var pendingSeek: TimeInterval?
    private var currentAudioKey: String?
    private var startupWatchdog: Task<Void, Never>?
    private var lastPositionSave = Date.distantPast

    init(
        api: LemonAPIClient, audioCache: AudioCache, artworkStore: ArtworkStore,
        defaults: UserDefaults = .standard, audioPolicy: AudioPlaybackPolicy? = nil,
        startupTimeout: Duration = .seconds(45)
    ) {
        self.api = api
        self.audioCache = audioCache
        self.artworkStore = artworkStore
        self.defaults = defaults
        self.audioPolicy = audioPolicy
        self.startupTimeout = startupTimeout

        let configuration = AudioPlayerConfiguration(
            flushQueueOnSeek: true,
            bufferSizeInSeconds: 20,
            secondsRequiredToStartPlaying: 1,
            gracePeriodAfterSeekInSeconds: 0.5,
            secondsRequiredToStartPlayingAfterBufferUnderrun: 1,
            enableLogs: false
        )
        let player = AudioPlayer(configuration: configuration, streamCache: audioCache.streamCache)
        let delegate = LemonAudioPlayerDelegate()
        self.player = player
        self.playerDelegate = delegate
        delegate.controller = self
        player.delegate = delegate
        audioCache.onStreamingProgress = { [weak self] key, downloaded, total in
            guard total > 0 else { return }
            let id = self?.currentAudioKey == key ? self?.currentTrack?.id ?? key : key
            self?.audioCacheStates[id] = .caching(min(1, Double(downloaded) / Double(total)))
        }
        audioCache.onStreamingCompleted = { [weak self] key in
            let id = self?.currentAudioKey == key ? self?.currentTrack?.id ?? key : key
            self?.audioCacheStates[id] = .cached
        }

        configureAudioSession()
        configureRemoteCommands()
        restoreQueue()
        startProgressLoop()
    }

    func play(_ track: MusicTrack, in tracks: [MusicTrack]? = nil) async {
        if let tracks, let index = tracks.firstIndex(of: track) {
            queueState.replace(with: tracks, selecting: tracks[index])
        } else if queueState.select(track) {
        } else {
            queueState.replace(with: [track], selecting: track)
        }
        await loadCurrentTrack(autoplay: true, forceRefresh: false)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        player.pause()
        isPlaying = false
        isBuffering = false
        startupWatchdog?.cancel()
        persistQueue()
        updateNowPlaying()
    }

    func stop() {
        startupWatchdog?.cancel()
        engineHasEntry = false
        pendingSeek = nil
        isLoadingTrack = false
        isBuffering = false
        player.stop()
        playbackRequest = PlaybackRequestState()
        audioCache.playingKey = nil
        isPlaying = false
        currentTrack = nil
        queueState = PlaybackQueue()
        position = 0
        duration = 0
        persistQueue()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func resume() {
        guard !isLoadingTrack else { return }
        guard currentTrack != nil, !queue.isEmpty else {
            reportFailure("没有可播放的歌曲，请重新选择歌曲", code: "empty-queue")
            return
        }
        if !engineHasEntry || lastError != nil || (duration > 0 && position >= duration - 0.5) {
            let resumeAt = !engineHasEntry && lastError == nil ? position : 0
            Task { await loadCurrentTrack(autoplay: true, forceRefresh: lastError != nil, resumeAt: resumeAt) }
            return
        }
        player.resume()
        isPlaying = true
        updateNowPlaying()
    }

    func next() async {
        guard !queue.isEmpty else { return }
        queueState.advance(natural: false)
        await loadCurrentTrack(autoplay: true, forceRefresh: false)
    }

    func previous() async {
        if position > 3 { seek(to: 0); return }
        queueState.retreat()
        await loadCurrentTrack(autoplay: true, forceRefresh: false)
    }

    func seek(to seconds: TimeInterval) {
        guard player.isSeekable else { return }
        player.seek(to: max(0, seconds))
        position = max(0, seconds)
        persistQueue()
        updateNowPlaying()
    }

    func addToQueue(_ tracks: [MusicTrack]) {
        queueState.append(tracks)
        persistQueue()
    }

    func playNext(_ track: MusicTrack) {
        queueState.insertNext(track)
        persistQueue()
    }

    func removeFromQueue(at offsets: IndexSet) {
        queueState.remove(at: offsets)
        persistQueue()
    }

    func moveQueue(from offsets: IndexSet, to destination: Int) {
        queueState.move(from: offsets, to: destination)
        persistQueue()
    }

    func setMode(_ mode: PlaybackMode) {
        queueState.setMode(mode)
        persistQueue()
    }

    func cycleMode() { setMode(mode.next) }

    func audioCacheState(for track: MusicTrack) -> AudioCacheState {
        if audioCache.availableCache(for: track, touching: false) != nil { return .cached }
        return audioCacheStates[track.id] ?? .notCached
    }

    func cancelAutomaticCaching() {
        audioCacheStates.removeAll()
    }

    func handlePlayerState(_ state: AudioPlayerState) {
        guard engineHasEntry else { return }
        isBuffering = state == .bufferring
        isPlaying = state == .playing
        updateNowPlaying()
    }

    func handleNaturalEnd(playbackID: String) async {
        guard playbackRequest.consumeEnd(for: playbackID) else { return }
        queueState.advance(natural: true)
        await loadCurrentTrack(autoplay: true, forceRefresh: false)
    }

    func handlePlaybackError(_ error: AudioPlayerError = .other) async {
        guard !isLoadingTrack, playbackRequest.id != nil else { return }
        let isInvalidAudio: Bool
        switch error {
        case .streamParseBytesFailure, .codecError, .dataNotFound: isInvalidAudio = true
        default: isInvalidAudio = false
        }
        if isInvalidAudio, (currentPlaybackUsesCache || currentPlaybackUsesPartialCache), let track = currentTrack {
            audioCache.remove(for: currentAudioKey ?? track.id)
            audioCacheStates[track.id] = .notCached
            currentPlaybackUsesCache = false
            currentPlaybackUsesPartialCache = false
        }
        guard !retryingCurrentItem else {
            isPlaying = false
            engineHasEntry = false
            isBuffering = false
            startupWatchdog?.cancel()
            reportFailure(playbackErrorMessage(error), code: "engine-error")
            return
        }
        logger.notice("音频引擎失败，执行一次重试")
        await loadCurrentTrack(autoplay: true, forceRefresh: true)
    }

    func handleStarted(playbackID: String) {
        guard playbackRequest.isCurrent(playbackID), engineHasEntry else { return }
        startupWatchdog?.cancel()
        isBuffering = false
        isPlaying = true
        if let target = pendingSeek, player.isSeekable {
            pendingSeek = nil
            let knownDuration = player.duration > 0 ? player.duration : duration
            seek(to: knownDuration > 0 ? max(0, min(target, knownDuration - 0.5)) : target)
        }
        logger.info("音频已开始播放")
        updateNowPlaying()
    }

    private func loadCurrentTrack(autoplay: Bool, forceRefresh: Bool, resumeAt: TimeInterval = 0) async {
        guard queue.indices.contains(currentIndex) else { return }
        let requestID = playbackRequest.begin()
        isPlaying = false
        startupWatchdog?.cancel()
        engineHasEntry = false
        isBuffering = false
        isLoadingTrack = true
        lastError = nil
        startStartupWatchdog(requestID)
        logger.info("开始加载音频，重试=\(forceRefresh)")
        defer { if playbackRequest.isCurrent(requestID) { isLoadingTrack = false } }
        let requestedTrack = queue[currentIndex]
        var track = await preferredTrack?(requestedTrack) ?? requestedTrack
        guard playbackRequest.isCurrent(requestID) else { return }
        audioCache.playingKey = track.id
        await willPlayTrack?(track)
        guard playbackRequest.isCurrent(requestID) else { return }
        currentTrack = track
        audioCache.playingKey = track.id
        onTrackChanged?()
        retryingCurrentItem = forceRefresh
        currentPlaybackUsesCache = false
        currentPlaybackUsesPartialCache = false

        do {
            try activateAudioSession()
            if let cached = audioCache.availableCache(for: track) {
                // Let the stream engine settle pending source changes during rapid cached selections.
                try await Task.sleep(for: .milliseconds(20))
                guard playbackRequest.isCurrent(requestID) else { return }
                currentAudioKey = cached.key
                audioCache.playingKey = cached.key
                currentPlaybackUsesCache = true
                audioCacheStates[track.id] = .cached
                engineHasEntry = true
                player.play(url: cached.url, playbackID: requestID)
            } else {
                var quality: String?
                if track.locator.kind == .online {
                    if let override = audioPolicy?.qualityOverride { quality = override }
                    else { quality = try await api.serverPlayQuality() }
                }
                guard playbackRequest.isCurrent(requestID) else { return }
                currentAudioKey = AudioVariant.key(for: track, quality: quality)
                audioCache.playingKey = currentAudioKey
                if let partial = audioCache.partialProgress(for: currentAudioKey!), partial.total > 0 {
                    audioCacheStates[track.id] = .caching(min(1, Double(partial.downloaded) / Double(partial.total)))
                    currentPlaybackUsesPartialCache = partial.downloaded > 0
                } else {
                    audioCacheStates[track.id] = .caching(0)
                }
                var streamURL: URL
                do {
                    streamURL = try await api.resolvePlayURL(for: track, refresh: forceRefresh, quality: quality)
                } catch LemonAPIClient.APIError.server(let status, _) where
                    [400, 404, 410].contains(status)
                    && track.locator.kind == .local && requestedTrack.locator.kind == .online {
                    guard playbackRequest.isCurrent(requestID) else { return }
                    track = requestedTrack
                    currentTrack = track
                    audioCache.playingKey = track.id
                    await willPlayTrack?(track)
                    guard playbackRequest.isCurrent(requestID) else { return }
                    onTrackChanged?()
                    currentPlaybackUsesPartialCache = false
                    audioCacheStates[track.id] = .caching(0)
                    if let override = audioPolicy?.qualityOverride { quality = override }
                    else { quality = try await api.serverPlayQuality() }
                    currentAudioKey = AudioVariant.key(for: track, quality: quality)
                    audioCache.playingKey = currentAudioKey
                    streamURL = try await api.resolvePlayURL(for: track, refresh: forceRefresh, quality: quality)
                }
                guard playbackRequest.isCurrent(requestID) else { return }
                engineHasEntry = true
                if track.locator.kind == .online, audioPolicy?.qualityOverride == "128k", quality != "128k" {
                    quality = "128k"
                    currentAudioKey = AudioVariant.key(for: track, quality: quality)
                    audioCache.playingKey = currentAudioKey
                    currentPlaybackUsesPartialCache = audioCache.partialProgress(for: currentAudioKey!) != nil
                    streamURL = try await api.resolvePlayURL(for: track, refresh: forceRefresh, quality: quality)
                    guard playbackRequest.isCurrent(requestID) else { return }
                }
                player.play(url: streamURL, playbackID: requestID, cacheKey: currentAudioKey)
            }

            lastError = nil
            duration = track.duration
            pendingSeek = resumeAt > 0 ? resumeAt : nil
            position = resumeAt
            isPlaying = autoplay
            if !autoplay { player.pause(); startupWatchdog?.cancel() }
            updateNowPlaying()
            persistQueue()
        } catch {
            guard playbackRequest.isCurrent(requestID) else { return }
            startupWatchdog?.cancel()
            engineHasEntry = false
            isBuffering = false
            audioCache.playingKey = nil
            onTrackChanged?()
            isPlaying = false
            audioCacheStates[track.id] = .failed
            let nsError = error as NSError
            reportFailure(networkErrorMessage(error), code: "\(nsError.domain):\(nsError.code)")
        }
    }

    private func startProgressLoop() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                guard self.engineHasEntry, !self.isLoadingTrack else { continue }
                let progress = self.player.progress
                let duration = self.player.duration
                if self.pendingSeek == nil, progress.isFinite { self.position = max(0, progress) }
                if duration.isFinite, duration > 0 { self.duration = duration }
                self.isPlaying = self.player.state == .playing
                self.isBuffering = self.player.state == .bufferring
                if self.pendingSeek != nil, self.player.state == .playing, self.player.isSeekable,
                   let playbackID = self.playbackRequest.id { self.handleStarted(playbackID: playbackID) }
                if Date().timeIntervalSince(self.lastPositionSave) >= 5 {
                    self.persistQueue()
                    self.lastPositionSave = Date()
                }
            }
        }
    }

    private func configureAudioSession() {
        do {
            try activateAudioSession()
        } catch {
            let failure = error as NSError
            logger.error("音频会话初始化失败，域=\(failure.domain, privacy: .public)，代码=\(failure.code)")
        }
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                Self.audioSessionCategory, mode: Self.audioSessionMode, options: Self.audioSessionOptions
            )
        } catch {
            throw AudioSessionSetupError(stage: "音频会话配置", underlying: error as NSError)
        }
        do {
            try session.setActive(true)
        } catch {
            throw AudioSessionSetupError(stage: "音频输出激活", underlying: error as NSError)
        }
    }

    private func startStartupWatchdog(_ requestID: String) {
        startupWatchdog = Task { [weak self, startupTimeout] in
            do { try await Task.sleep(for: startupTimeout) } catch { return }
            guard let self, self.playbackRequest.isCurrent(requestID), !self.isPlaying else { return }
            self.playbackRequest = PlaybackRequestState()
            self.player.stop()
            self.engineHasEntry = false
            self.isLoadingTrack = false
            self.isBuffering = false
            self.audioCache.playingKey = nil
            self.reportFailure("音频加载超时，请检查服务器、网络和音源后重试", code: "startup-timeout")
        }
    }

    private func reportFailure(_ message: String, code: String) {
        isPlaying = false
        lastError = message
        logger.error("播放失败，代码=\(code, privacy: .public)")
        updateNowPlaying()
    }

    private func playbackErrorMessage(_ error: AudioPlayerError) -> String {
        switch error {
        case .streamParseBytesFailure, .codecError: "音频格式无法解析，文件可能损坏或不受支持，请重试"
        case .dataNotFound: "没有收到可播放的音频数据，请检查服务器或音源"
        case .networkError: "音频流连接失败，请检查网络、服务器和音源后重试"
        case .audioSystemError: "音频引擎无法启动，请重试或检查音频输出设备"
        case .other: "播放失败，请重新加载歌曲"
        }
    }

    private func networkErrorMessage(_ error: Error) -> String {
        guard let error = error as? URLError else { return error.localizedDescription }
        switch error.code {
        case .notConnectedToInternet: return "当前网络不可用，且这首歌曲没有完整本机缓存"
        case .timedOut: return "服务器响应超时，请检查网络或稍后重试"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "无法连接音乐服务器，请检查服务器地址和网络"
        default: return "无法加载音频：\(error.localizedDescription)"
        }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        commands.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        let requestID = playbackRequest.id
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: max(duration, track.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1 : 0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        Task { [weak self] in
            guard let self, let image = await self.artworkStore.image(for: track, api: self.api) else { return }
            guard self.playbackRequest.id == requestID, self.currentTrack?.id == track.id else { return }
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func persistQueue() {
        if let state = try? JSONEncoder().encode(queueState) {
            defaults.set(state, forKey: "lemon.playback.state")
        }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: "lemon.playback.queue")
        defaults.set(currentIndex, forKey: "lemon.playback.index")
        defaults.set(position, forKey: "lemon.playback.position")
    }

    private func restoreQueue() {
        if let data = defaults.data(forKey: "lemon.playback.state"),
           let state = try? JSONDecoder().decode(PlaybackQueue.self, from: data) {
            queueState = state
            currentTrack = queueState.current?.track
            position = defaults.double(forKey: "lemon.playback.position")
            duration = currentTrack?.duration ?? 0
            return
        }
        guard let data = defaults.data(forKey: "lemon.playback.queue"),
              let tracks = try? JSONDecoder().decode([MusicTrack].self, from: data), !tracks.isEmpty else { return }
        let index = min(max(0, defaults.integer(forKey: "lemon.playback.index")), tracks.count - 1)
        queueState.replace(with: tracks, selecting: tracks[index])
        currentTrack = tracks[index]
        position = defaults.double(forKey: "lemon.playback.position")
        duration = currentTrack?.duration ?? 0
        if let track = currentTrack, audioCache.cachedURL(for: track.id) != nil {
            audioCacheStates[track.id] = .cached
        }
    }
}

private struct AudioSessionSetupError: LocalizedError {
    let stage: String
    let underlying: NSError

    var errorDescription: String? {
        "\(stage)失败（\(underlying.domain)，错误码 \(underlying.code)），请重试或检查音频输出设备"
    }
}

nonisolated final class LemonAudioPlayerDelegate: AudioPlayerDelegate, @unchecked Sendable {
    nonisolated(unsafe) weak var controller: PlaybackController?

    func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId) {
        Task { @MainActor [weak controller] in controller?.handleStarted(playbackID: entryId.id) }
    }
    func audioPlayerDidFinishBuffering(player: AudioPlayer, with entryId: AudioEntryId) {}

    func audioPlayerStateChanged(player: AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {
        Task { @MainActor [weak controller] in controller?.handlePlayerState(newState) }
    }

    func audioPlayerDidFinishPlaying(
        player: AudioPlayer,
        entryId: AudioEntryId,
        stopReason: AudioPlayerStopReason,
        progress: Double,
        duration: Double
    ) {
        guard stopReason == .eof else { return }
        Task { @MainActor [weak controller] in await controller?.handleNaturalEnd(playbackID: entryId.id) }
    }

    func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError) {
        Task { @MainActor [weak controller] in await controller?.handlePlaybackError(error) }
    }

    func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId]) {}
    func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String]) {}
}
