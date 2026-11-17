import OSLog
import UIKit
import WidgetKit

@MainActor
final class PlaybackWidgetPublisher {
    private let store: PlaybackWidgetStore
    private var lastSnapshot: PlaybackWidgetSnapshot
    private let reload: () -> Void
    private let logger = Logger(subsystem: "top.btop.music", category: "Widget")

    init(store: PlaybackWidgetStore = PlaybackWidgetStore(), reload: @escaping () -> Void = {
        WidgetCenter.shared.reloadTimelines(ofKind: PlaybackWidgetSnapshot.kind)
    }) {
        self.store = store
        self.reload = reload
        lastSnapshot = store.read()
    }

    func update(track: MusicTrack?, isPlaying: Bool, isSignedIn: Bool, artwork: UIImage? = nil) {
        var snapshot = PlaybackWidgetSnapshot(isSignedIn: isSignedIn)
        if isSignedIn, let track {
            snapshot.trackID = track.id
            snapshot.title = track.title
            snapshot.artist = track.artist
            snapshot.isPlaying = isPlaying
            if lastSnapshot.trackID == track.id { snapshot.artworkFilename = lastSnapshot.artworkFilename }
        }
        var imageData: Data?
        if snapshot.hasTrack, let artwork, snapshot.artworkFilename == nil {
            let size = CGSize(width: 240, height: 240)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                let scale = max(size.width / artwork.size.width, size.height / artwork.size.height)
                let scaled = CGSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
                artwork.draw(in: CGRect(x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2,
                                       width: scaled.width, height: scaled.height))
            }
            imageData = image.jpegData(compressionQuality: 0.85)
            if imageData != nil { snapshot.artworkFilename = "\(UUID().uuidString).jpg" }
        }
        guard snapshot != lastSnapshot else { return }
        do {
            try store.save(snapshot, artwork: imageData)
            lastSnapshot = snapshot
            reload()
        } catch {
            logger.error("无法更新小组件：\(error.localizedDescription, privacy: .public)")
        }
    }
}
