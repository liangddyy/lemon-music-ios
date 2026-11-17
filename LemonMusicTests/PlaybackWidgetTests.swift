import Foundation
import Testing
import UIKit
@testable import LemonMusic

struct PlaybackWidgetTests {
    @Test func missingAndCorruptSnapshotsShowSignedOutState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackWidgetStore(directory: directory)
        #expect(store.read() == .signedOut)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("playback.json"))
        #expect(store.read() == .signedOut)
    }

    @Test func snapshotAndArtworkRoundTripAndLogoutClearsPrivateData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackWidgetStore(directory: directory)
        let snapshot = PlaybackWidgetSnapshot(
            isSignedIn: true, trackID: "local:1", title: "歌曲", artist: "歌手", isPlaying: true, artworkFilename: "cover.jpg"
        )
        let cover = Data([1, 2, 3])
        try store.save(snapshot, artwork: cover)
        #expect(store.read() == snapshot)
        #expect(store.artwork(for: snapshot) == cover)
        try store.save(.signedOut)
        #expect(store.read() == .signedOut)
        #expect(store.artwork(for: snapshot) == nil)
    }

    @Test func artworkPathsCannotEscapeSharedDirectory() {
        let store = PlaybackWidgetStore(directory: FileManager.default.temporaryDirectory)
        let snapshot = PlaybackWidgetSnapshot(isSignedIn: true, artworkFilename: "../playback.json")
        #expect(store.artwork(for: snapshot) == nil)
    }

    @MainActor @Test func publisherDeduplicatesStateAndRejectsStaleCoversOnTrackChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackWidgetStore(directory: directory)
        var reloads = 0
        let publisher = PlaybackWidgetPublisher(store: store, reload: { reloads += 1 })
        let first = try track(id: "first")
        let second = try track(id: "second")
        publisher.update(track: first, isPlaying: true, isSignedIn: true)
        publisher.update(track: first, isPlaying: true, isSignedIn: true)
        #expect(reloads == 1)
        #expect(store.read().isPlaying)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        publisher.update(track: first, isPlaying: true, isSignedIn: true, artwork: image)
        let snapshot = store.read()
        #expect(snapshot.artworkFilename != nil)
        let data = try #require(store.artwork(for: snapshot))
        #expect(UIImage(data: data)?.size == CGSize(width: 240, height: 240))
        publisher.update(track: first, isPlaying: false, isSignedIn: true)
        #expect(store.read().artworkFilename == snapshot.artworkFilename)
        #expect(!store.read().isPlaying)
        publisher.update(track: second, isPlaying: true, isSignedIn: true)
        #expect(store.read().trackID == second.id)
        #expect(store.read().artworkFilename == nil)
        publisher.update(track: second, isPlaying: true, isSignedIn: false)
        #expect(store.read() == .signedOut)
        #expect(store.artwork(for: snapshot) == nil)
    }

    private func track(id: String) throws -> MusicTrack {
        try #require(MusicTrack(json: .object([
            "trackId": .string(id), "title": .string(id), "filePath": .string("/\(id).mp3"),
        ])))
    }
}
