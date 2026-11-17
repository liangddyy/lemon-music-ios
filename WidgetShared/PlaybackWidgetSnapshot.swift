import Foundation

nonisolated struct PlaybackWidgetSnapshot: Codable, Equatable, Sendable {
    static let kind = "LemonMusicPlayback"
    static let appGroup = "group.top.btop.music"
    static let playerURL = URL(string: "lemonmusic://player")!
    static let signedOut = PlaybackWidgetSnapshot(isSignedIn: false)

    var isSignedIn: Bool
    var trackID: String?
    var title = "柠檬音乐"
    var artist = ""
    var isPlaying = false
    var artworkFilename: String?

    var hasTrack: Bool { isSignedIn && trackID != nil }
}

nonisolated struct PlaybackWidgetStore {
    let directory: URL?

    init(directory: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: PlaybackWidgetSnapshot.appGroup
    )?.appendingPathComponent("PlaybackWidget", isDirectory: true)) {
        self.directory = directory
    }

    func read() -> PlaybackWidgetSnapshot {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("playback.json")),
              let snapshot = try? JSONDecoder().decode(PlaybackWidgetSnapshot.self, from: data) else {
            return .signedOut
        }
        return snapshot
    }

    func artwork(for snapshot: PlaybackWidgetSnapshot) -> Data? {
        guard let directory, let filename = snapshot.artworkFilename,
              filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(filename))
    }

    func save(_ snapshot: PlaybackWidgetSnapshot, artwork: Data? = nil) throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let artwork, let filename = snapshot.artworkFilename,
           filename == URL(fileURLWithPath: filename).lastPathComponent {
            try artwork.write(to: directory.appendingPathComponent(filename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: directory.appendingPathComponent("playback.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { $0.pathExtension == "jpg" }
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in sorted.dropFirst(snapshot.isSignedIn ? 4 : 0) where file.lastPathComponent != snapshot.artworkFilename {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
