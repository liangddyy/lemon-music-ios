import Foundation
import Observation

nonisolated struct ServerPlaybackSettings: Codable, Equatable, Sendable {
    var quality = "128k"
    var smooth = false
}

@Observable @MainActor
final class AudioPlaybackPolicy {
    private let defaults: UserDefaults
    private(set) var isCellular = false
    private(set) var isConnected = true
    var onChange: (() -> Void)?
    private(set) var serverSettings: ServerPlaybackSettings
    var dataSaverEnabled: Bool {
        didSet {
            defaults.set(dataSaverEnabled, forKey: "lemon.audio.dataSaver")
            if oldValue != dataSaverEnabled { onChange?() }
        }
    }

    var qualityOverride: String? { serverSettings.smooth || (dataSaverEnabled && isCellular) ? "128k" : nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dataSaverEnabled = defaults.object(forKey: "lemon.audio.dataSaver") as? Bool ?? true
        serverSettings = defaults.data(forKey: "lemon.audio.serverSettings")
            .flatMap { try? JSONDecoder().decode(ServerPlaybackSettings.self, from: $0) } ?? ServerPlaybackSettings()
    }

    func applyServerSettings(_ settings: ServerPlaybackSettings) {
        guard serverSettings != settings else { return }
        serverSettings = settings
        defaults.set(try? JSONEncoder().encode(settings), forKey: "lemon.audio.serverSettings")
        onChange?()
    }

    func updateNetwork(cellular: Bool, connected: Bool = true) {
        guard isCellular != cellular || isConnected != connected else { return }
        isCellular = cellular
        isConnected = connected
        onChange?()
    }
}

nonisolated enum AudioVariant {
    static func key(for track: MusicTrack, quality: String?, smooth: Bool = false) -> String {
        if track.locator.kind == .local, usesAAC(for: track, smooth: smooth) {
            return track.id + "|format:aac128"
        }
        guard track.locator.kind == .online, let quality else { return track.id }
        return track.id + "|quality:" + quality
    }

    static func matches(_ key: String?, trackID: String) -> Bool {
        key == trackID || key?.hasPrefix(trackID + "|quality:") == true
            || key?.hasPrefix(trackID + "|format:") == true
    }

    static func usesAAC(for track: MusicTrack, smooth: Bool) -> Bool {
        guard track.locator.kind == .local, let path = track.locator.filePath else { return false }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["dsf", "dff"].contains(ext) { return true }
        return smooth && ["flac", "wav", "aiff", "aif", "wv", "tak"].contains(ext)
    }
}
