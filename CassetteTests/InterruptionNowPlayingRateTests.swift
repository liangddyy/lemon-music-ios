// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import AVFoundation
import Foundation
import SwiftSonic
import Testing
@testable import Cassette

// Locks the now-playing rate on a pause the user did not ask for. An interruption `.began` (a
// Bluetooth disconnect, a call, Siri) paused the engine but left rate 1 on the lock screen — and on
// CarPlay's — so the screen kept showing "playing" and the first press on play was spent on a pause.
// A radio had the same gap on every pause: it has no track, and the position push stops without one.

/// Records what PlayerService sends to the now-playing surfaces. MainActor, like the protocol
/// under this project's default isolation.
@MainActor
private final class NowPlayingSpy: NowPlayingServiceProtocol {
    private(set) var snapshots: [NowPlayingSnapshot] = []
    private(set) var pushedRates: [Float] = []

    func start() async {}
    func stop() async {}
    func setFavoritesService(_ service: any FavoritesServiceProtocol) async {}
    func update(with snapshot: NowPlayingSnapshot) async { snapshots.append(snapshot) }
    func pushPosition(elapsed: TimeInterval, rate: Float, duration: TimeInterval) async {}
    func pushPlaybackRate(_ rate: Float) async { pushedRates.append(rate) }
}

private func makeSong() -> DisplayableSong {
    DisplayableSong(
        id: "s1", title: "Motion Picture Soundtrack", artist: "Radiohead",
        albumId: "alb1", albumName: "Kid A", artistId: "art1",
        genre: nil, duration: 300, trackNumber: 10, isDownloaded: false,
        coverArtId: nil, audioFormat: nil,
        replayGainTrackGain: nil, replayGainTrackPeak: nil,
        replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
        replayGainBaseGain: nil, replayGainFallbackGain: nil
    )
}

/// SwiftSonic's station has no public memberwise init; decoding is how the app gets one too.
private func makeStation() throws -> InternetRadioStation {
    let json = #"{"id":"r1","name":"FIP","streamUrl":"https://radio.invalid/fip.mp3"}"#
    return try JSONDecoder().decode(InternetRadioStation.self, from: Data(json.utf8))
}

private func interruptionBegan() -> Notification {
    Notification(
        name: AVAudioSession.interruptionNotification,
        object: nil,
        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
    )
}

/// A real PlayerService on an in-memory container, with the spy in place of NowPlayingService.
/// The container is returned so it outlives the test body.
private func makePlayer() async throws -> (AppContainer, PlayerService, NowPlayingSpy) {
    let container = try AppContainer(inMemory: true)
    let player = try #require(container.playerService as? PlayerService)
    let spy = NowPlayingSpy()
    await player.setNowPlayingService(spy)
    return (container, player, spy)
}

// Serialized: every PlayerService here drives the one shared AVAudioSession.
@Suite("Now-playing rate on pause and interruption", .serialized)
struct InterruptionNowPlayingRateTests {

    @Test("interruption began while a track plays pushes rate 0")
    func interruptionBeganTrackPushesRateZero() async throws {
        let (container, player, spy) = try await makePlayer()
        container.playerState.currentTrack = makeSong()
        container.playerState.duration = 300
        container.playerState.position = 42
        container.playerState.playbackState = .playing

        await player.handleAudioSessionInterruption(interruptionBegan())

        #expect(container.playerState.playbackState == .paused)
        let last = try #require(spy.snapshots.last)
        #expect(last.playbackRate == 0)
        #expect(last.songId == "s1")
        #expect(last.position == 42)
    }

    @Test("interruption began while a radio plays pushes rate 0")
    func interruptionBeganRadioPushesRateZero() async throws {
        let (container, player, spy) = try await makePlayer()
        container.playerState.currentRadio = try makeStation()
        container.playerState.playbackState = .playing

        await player.handleAudioSessionInterruption(interruptionBegan())

        #expect(container.playerState.playbackState == .paused)
        #expect(spy.pushedRates == [0])
    }

    @Test("user pause on a radio pushes rate 0")
    func pauseRadioPushesRateZero() async throws {
        let (container, player, spy) = try await makePlayer()
        container.playerState.currentRadio = try makeStation()
        container.playerState.playbackState = .playing

        await player.pause()

        #expect(spy.pushedRates == [0])
    }

    @Test("resume on a paused radio pushes rate 1")
    func resumeRadioPushesRateOne() async throws {
        let (container, player, spy) = try await makePlayer()
        container.playerState.currentRadio = try makeStation()
        container.playerState.playbackState = .paused

        await player.resume()

        #expect(spy.pushedRates == [1])
    }
}
#endif
