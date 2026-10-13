import Foundation
import Testing
import UIKit
@testable import LemonMusic

@MainActor
struct ArtworkStoreTests {
    @Test func longUnicodeCoverIdentityFitsFilesystemAndSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "local:/music/" + String(repeating: "中文目录/", count: 60) + "song.flac"
        let url = try coverURL(color: .red)
        let store = ArtworkStore(directory: directory)
        #expect(await store.image(key: key, remoteURL: url) != nil)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(files.first?.lastPathComponent.utf8.count == 68)
        #expect(await ArtworkStore(directory: directory).image(key: key, remoteURL: url) != nil)
    }

    @Test func uploadedPlaylistCoverUsesCacheAndChangesWithCoverURL() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArtworkStore(directory: directory)
        let redURL = try coverURL(color: .red)
        let blueURL = try coverURL(color: .blue)
        let first = try #require(await store.image(key: "playlist:p1", remoteURL: redURL))
        let repeated = try #require(await store.image(key: "playlist:p1", remoteURL: redURL))
        #expect(first === repeated)
        let changed = try #require(await store.image(key: "playlist:p1", remoteURL: blueURL))
        #expect(changed.pngData() != first.pngData())
        let reopened = ArtworkStore(directory: directory)
        let diskImage = await reopened.image(key: "playlist:p1", remoteURL: blueURL)
        #expect(diskImage != nil)
    }

    private func coverURL(color: UIColor) throws -> String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let data = try #require(image.pngData())
        return "data:image/png;base64,\(data.base64EncodedString())"
    }
}
