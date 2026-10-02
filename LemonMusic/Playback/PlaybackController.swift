// Derived from Cassette, licensed under MPL-2.0.

import AudioStreaming
import AVFAudio
import Foundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

@Observable
@MainActor
final class PlaybackController {
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
    private var progressTask: Task<Void, Never>?
    private var retryingCurrentItem = false
    private var currentPlaybackUsesCache = false
    private var currentPlaybackUsesPartialCache = false
    private var playbackRequest = PlaybackRequestState()
    private var isLoadingTrack = false

    init(api: LemonAPIClient, audioCache: AudioCache, artworkStore: ArtworkStore, defaults: UserDefaults = .standard) {
        self.api = api
        self.audioCache = audioCache
        self.artworkStore = artworkStore
        self.defaults = defaults

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
            self?.audioCacheStates[key] = .caching(min(1, Double(downloaded) / Double(total)))
        }
        audioCache.onStreamingCompleted = { [weak self] key in
            self?.audioCacheStates[key] = .cached
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
        updateNowPlaying()
    }

    func stop() {
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
        if duration > 0, position >= duration - 0.5 {
            Task { await loadCurrentTrack(autoplay: true, forceRefresh: false) }
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
        if audioCache.cachedURL(for: track.id) != nil { return .cached }
        return audioCacheStates[track.id] ?? .notCached
    }

    func cancelAutomaticCaching() {
        audioCacheStates.removeAll()
    }

    func handlePlayerState(_ state: AudioPlayerState) {
        isPlaying = state == .playing
        updateNowPlaying()
    }

    func handleNaturalEnd(playbackID: String) async {
        guard playbackRequest.consumeEnd(for: playbackID) else { return }
        queueState.advance(natural: true)
        await loadCurrentTrack(autoplay: true, forceRefresh: false)
    }

    func handlePlaybackError() async {
        guard !isLoadingTrack, playbackRequest.id != nil else { return }
        if (currentPlaybackUsesCache || currentPlaybackUsesPartialCache), let track = currentTrack {
            audioCache.remove(for: track.id)
            audioCacheStates[track.id] = .notCached
            currentPlaybackUsesCache = false
            currentPlaybackUsesPartialCache = false
        }
        guard !retryingCurrentItem else {
            isPlaying = false
            return
        }
        await loadCurrentTrack(autoplay: true, forceRefresh: true)
    }

    private func loadCurrentTrack(autoplay: Bool, forceRefresh: Bool) async {
        guard queue.indices.contains(currentIndex) else { return }
        let requestID = playbackRequest.begin()
        isLoadingTrack = true
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
            if let cachedURL = audioCache.cachedURL(for: track.id) {
                currentPlaybackUsesCache = true
                audioCacheStates[track.id] = .cached
                player.play(url: cachedURL, playbackID: requestID)
            } else {
                if let partial = audioCache.partialProgress(for: track.id), partial.total > 0 {
                    audioCacheStates[track.id] = .caching(min(1, Double(partial.downloaded) / Double(partial.total)))
                    currentPlaybackUsesPartialCache = partial.downloaded > 0
                } else {
                    audioCacheStates[track.id] = .caching(0)
                }
                let streamURL: URL
                do {
                    streamURL = try await api.resolvePlayURL(for: track, refresh: forceRefresh)
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
                    streamURL = try await api.resolvePlayURL(for: track, refresh: forceRefresh)
                }
                guard playbackRequest.isCurrent(requestID) else { return }
                player.play(url: streamURL, playbackID: requestID, cacheKey: track.id)
            }

            lastError = nil
            duration = track.duration
            position = 0
            isPlaying = autoplay
            if !autoplay { player.pause() }
            updateNowPlaying()
            persistQueue()
        } catch {
            guard playbackRequest.isCurrent(requestID) else { return }
            audioCache.playingKey = nil
            onTrackChanged?()
            isPlaying = false
            audioCacheStates[track.id] = .failed
            lastError = error.localizedDescription
        }
    }

    private func startProgressLoop() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let progress = self.player.progress
                let duration = self.player.duration
                if progress.isFinite { self.position = max(0, progress) }
                if duration.isFinite, duration > 0 { self.duration = duration }
                self.isPlaying = self.player.state == .playing
            }
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
        try? session.setActive(true)
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
            return
        }
        guard let data = defaults.data(forKey: "lemon.playback.queue"),
              let tracks = try? JSONDecoder().decode([MusicTrack].self, from: data), !tracks.isEmpty else { return }
        let index = min(max(0, defaults.integer(forKey: "lemon.playback.index")), tracks.count - 1)
        queueState.replace(with: tracks, selecting: tracks[index])
        currentTrack = tracks[index]
        position = defaults.double(forKey: "lemon.playback.position")
        if let track = currentTrack, audioCache.cachedURL(for: track.id) != nil {
            audioCacheStates[track.id] = .cached
        }
    }
}

nonisolated final class LemonAudioPlayerDelegate: AudioPlayerDelegate, @unchecked Sendable {
    nonisolated(unsafe) weak var controller: PlaybackController?

    func audioPlayerDidStartPlaying(player: AudioPlayer, with entryId: AudioEntryId) {}
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
        Task { @MainActor [weak controller] in await controller?.handlePlaybackError() }
    }

    func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId]) {}
    func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String]) {}
}
