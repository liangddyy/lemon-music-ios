import Foundation
import Observation

@Observable @MainActor
final class AudioPlaybackPolicy {
    private let defaults: UserDefaults
    private(set) var isCellular = false
    var onChange: (() -> Void)?
    var dataSaverEnabled: Bool {
        didSet {
            defaults.set(dataSaverEnabled, forKey: "lemon.audio.dataSaver")
            if oldValue != dataSaverEnabled { onChange?() }
        }
    }

    var qualityOverride: String? { dataSaverEnabled && isCellular ? "128k" : nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dataSaverEnabled = defaults.object(forKey: "lemon.audio.dataSaver") as? Bool ?? true
    }

    func updateNetwork(cellular: Bool) {
        guard isCellular != cellular else { return }
        isCellular = cellular
        onChange?()
    }
}

nonisolated enum AudioVariant {
    static func key(for track: MusicTrack, quality: String?) -> String {
        guard track.locator.kind == .online, let quality else { return track.id }
        return track.id + "|quality:" + quality
    }

    static func matches(_ key: String?, trackID: String) -> Bool {
        key == trackID || key?.hasPrefix(trackID + "|quality:") == true
    }
}
