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
    private(set) var currentTrack: MusicTrack?
    private(set) var queue: [MusicTrack] = []
    private(set) var currentIndex = 0
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var lastError: String?
    var repeatMode = false
    var isShuffled = false
    var showingFullPlayer = false

    private nonisolated(unsafe) let player: AudioPlayer
    private let playerDelegate: LemonAudioPlayerDelegate
    private let api: LemonAPIClient
    private let audioCache: AudioCache
    private let artworkStore: ArtworkStore
    private var progressTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var retryingCurrentItem = false
    private var originalQueue: [MusicTrack]?

    init(api: LemonAPIClient, audioCache: AudioCache, artworkStore: ArtworkStore) {
        self.api = api
        self.audioCache = audioCache
        self.artworkStore = artworkStore

        let configuration = AudioPlayerConfiguration(
            flushQueueOnSeek: true,
            bufferSizeInSeconds: 20,
            secondsRequiredToStartPlaying: 1,
            gracePeriodAfterSeekInSeconds: 0.5,
            secondsRequiredToStartPlayingAfterBufferUnderrun: 1,
            enableLogs: false
        )
        let player = AudioPlayer(configuration: configuration)
        let delegate = LemonAudioPlayerDelegate()
        self.player = player
        self.playerDelegate = delegate
        delegate.controller = self
        player.delegate = delegate

        configureAudioSession()
        configureRemoteCommands()
        restoreQueue()
        startProgressLoop()
    }

    func play(_ track: MusicTrack, in tracks: [MusicTrack]? = nil) async {
        if let tracks, let index = tracks.firstIndex(of: track) {
            queue = tracks
            currentIndex = index
        } else if let index = queue.firstIndex(of: track) {
            currentIndex = index
        } else {
            queue = [track]
            currentIndex = 0
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

    func resume() {
        player.resume()
        isPlaying = true
        updateNowPlaying()
    }

    func next() async {
        guard !queue.isEmpty else { return }
        if currentIndex + 1 < queue.count { currentIndex += 1 }
        else if repeatMode { currentIndex = 0 }
        else { pause(); return }
        await loadCurrentTrack(autoplay: true, forceRefresh: false)
    }

    func previous() async {
        if position > 3 { seek(to: 0); return }
        guard currentIndex > 0 else { seek(to: 0); return }
        currentIndex -= 1
        await loadCurrentTrack(autoplay: true, forceRefresh: false)
    }

    func seek(to seconds: TimeInterval) {
        guard player.isSeekable else { return }
        player.seek(to: max(0, seconds))
        position = max(0, seconds)
        updateNowPlaying()
    }

    func addToQueue(_ tracks: [MusicTrack]) {
        queue.append(contentsOf: tracks)
        persistQueue()
    }

    func playNext(_ track: MusicTrack) {
        let insertion = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertion)
        persistQueue()
    }

    func removeFromQueue(at offsets: IndexSet) {
        for offset in offsets.sorted(by: >) where offset != currentIndex {
            queue.remove(at: offset)
            if offset < currentIndex { currentIndex -= 1 }
        }
        persistQueue()
    }

    func moveQueue(from offsets: IndexSet, to destination: Int) {
        queue.move(fromOffsets: offsets, toOffset: destination)
        if let track = currentTrack, let index = queue.firstIndex(of: track) { currentIndex = index }
        persistQueue()
    }

    func toggleShuffle() {
        guard !queue.isEmpty else { return }
        if isShuffled, let originalQueue, let currentTrack {
            queue = originalQueue
            currentIndex = queue.firstIndex(of: currentTrack) ?? 0
            self.originalQueue = nil
        } else if let currentTrack {
            originalQueue = queue
            let remaining = queue.enumerated().filter { $0.offset != currentIndex }.map(\.element).shuffled()
            queue = [currentTrack] + remaining
            currentIndex = 0
        }
        isShuffled.toggle()
        persistQueue()
    }

    func handlePlayerState(_ state: AudioPlayerState) {
        isPlaying = state == .playing
        updateNowPlaying()
    }

    func handleNaturalEnd() async {
        await next()
    }

    func handlePlaybackError() async {
        guard !retryingCurrentItem else {
            isPlaying = false
            return
        }
        await loadCurrentTrack(autoplay: true, forceRefresh: true)
    }

    private func loadCurrentTrack(autoplay: Bool, forceRefresh: Bool) async {
        guard queue.indices.contains(currentIndex) else { return }
        let track = queue[currentIndex]
        currentTrack = track
        cacheTask?.cancel()
        retryingCurrentItem = forceRefresh

        do {
            let url: URL
            if let cachedURL = audioCache.cachedURL(for: track.id) {
                url = cachedURL
            } else {
                url = try await api.resolvePlayURL(for: track, refresh: forceRefresh)
            }

            player.stop()
            player.play(url: url)
            lastError = nil
            duration = track.duration
            position = 0
            isPlaying = autoplay
            if !autoplay { player.pause() }
            updateNowPlaying()
            persistQueue()
            if !url.isFileURL { scheduleAutomaticCache(track: track, streamURL: url) }
        } catch {
            isPlaying = false
            lastError = error.localizedDescription
        }
    }

    private func scheduleAutomaticCache(track: MusicTrack, streamURL: URL) {
        cacheTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.currentTrack?.id == track.id else { return }
            if self.audioCache.cachedURL(for: track.id) != nil { return }
            do {
                let configuration = URLSessionConfiguration.default
                configuration.allowsExpensiveNetworkAccess = self.audioCache.cacheOverCellular
                configuration.timeoutIntervalForResource = 15 * 60
                let session = URLSession(configuration: configuration)
                let (temporaryURL, response) = try await session.download(from: streamURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
                _ = try self.audioCache.storeDownloadedFile(
                    at: temporaryURL,
                    key: track.id,
                    mimeType: response.mimeType ?? "audio/mpeg",
                    protectedKey: self.currentTrack?.id
                )
            } catch {
                // Automatic cache is best effort and must not interrupt playback.
            }
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
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func persistQueue() {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        UserDefaults.standard.set(data, forKey: "lemon.playback.queue")
        UserDefaults.standard.set(currentIndex, forKey: "lemon.playback.index")
        UserDefaults.standard.set(position, forKey: "lemon.playback.position")
    }

    private func restoreQueue() {
        guard let data = UserDefaults.standard.data(forKey: "lemon.playback.queue"),
              let tracks = try? JSONDecoder().decode([MusicTrack].self, from: data), !tracks.isEmpty else { return }
        queue = tracks
        currentIndex = min(UserDefaults.standard.integer(forKey: "lemon.playback.index"), tracks.count - 1)
        currentTrack = tracks[currentIndex]
        position = UserDefaults.standard.double(forKey: "lemon.playback.position")
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
        Task { @MainActor [weak controller] in await controller?.handleNaturalEnd() }
    }

    func audioPlayerUnexpectedError(player: AudioPlayer, error: AudioPlayerError) {
        Task { @MainActor [weak controller] in await controller?.handlePlaybackError() }
    }

    func audioPlayerDidCancel(player: AudioPlayer, queuedItems: [AudioEntryId]) {}
    func audioPlayerDidReadMetadata(player: AudioPlayer, metadata: [String: String]) {}
}
