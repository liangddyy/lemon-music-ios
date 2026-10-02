// Derived from Cassette, licensed under MPL-2.0.

import CryptoKit
import Foundation
import UIKit

@MainActor
final class ArtworkStore {
    private let directory: URL
    private var memory: [String: UIImage] = [:]
    private var accessOrder: [String] = []
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let maxMemoryEntries = 100
    private let maxDiskBytes: Int64 = 500 * 1_024 * 1_024

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lemon-music/artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        garbageCollect()
    }

    func image(for track: MusicTrack, api: LemonAPIClient) async -> UIImage? {
        await image(key: track.id, targetSize: CGSize(width: 900, height: 900)) {
            try? await api.coverData(for: track)
        }
    }

    func image(for album: MusicAlbum) async -> UIImage? {
        await image(key: "album:\(album.id)", remoteURL: album.artworkURL)
    }

    func image(key: String, remoteURL: String?) async -> UIImage? {
        guard let rawURL = remoteURL, let url = URL(string: rawURL) else { return nil }
        let digest = SHA256.hash(data: Data(rawURL.utf8)).map { String(format: "%02x", $0) }.joined()
        return await image(key: "\(key).\(digest)", targetSize: CGSize(width: 600, height: 600)) {
            if rawURL.hasPrefix("data:image/") {
                let parts = rawURL.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0].hasSuffix(";base64") else { return nil }
                return Data(base64Encoded: String(parts[1]))
            }
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let result = try? await URLSession.shared.data(for: request),
                  let response = result.1 as? HTTPURLResponse,
                  response.statusCode == 200 else { return nil }
            return result.0
        }
    }

    private func image(
        key: String,
        targetSize: CGSize,
        loader: @escaping () async -> Data?
    ) async -> UIImage? {
        if let image = memory[key] { touch(key); return image }
        let diskURL = fileURL(for: key)
        if let image = UIImage(contentsOfFile: diskURL.path) {
            storeMemory(image, key: key)
            return image
        }
        if let inflight = inflight[key] { return await inflight.value }

        let task = Task<UIImage?, Never> {
            guard let data = await loader(),
                  let image = UIImage(data: data)?.preparingThumbnail(of: targetSize) else { return nil }
            let encoded = image.jpegData(compressionQuality: 0.88) ?? data
            try? encoded.write(to: diskURL, options: .atomic)
            return image
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { storeMemory(image, key: key) }
        return image
    }

    func clear() {
        memory.removeAll()
        accessOrder.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func storeMemory(_ image: UIImage, key: String) {
        memory[key] = image
        touch(key)
        while accessOrder.count > maxMemoryEntries, let first = accessOrder.first {
            accessOrder.removeFirst()
            memory.removeValue(forKey: first)
        }
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func fileURL(for key: String) -> URL {
        let safe = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(safe + ".jpg")
    }

    private func garbageCollect() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        ) else { return }
        var entries = files.map { url -> (URL, Int64, Date) in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey])
            return (url, Int64(values?.fileSize ?? 0), values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        while total > maxDiskBytes, !entries.isEmpty {
            let entry = entries.removeFirst()
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}
