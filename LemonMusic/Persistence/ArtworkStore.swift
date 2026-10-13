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
    private var failures: [String: Date] = [:]
    private var generation = UUID()
    private let maxMemoryEntries = 100
    private let maxDiskBytes: Int64 = 500 * 1_024 * 1_024

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lemon-music/artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        garbageCollect()
    }

    func image(for track: MusicTrack, api: LemonAPIClient) async -> UIImage? {
        let identity = track.id + "." + digest(track.artworkURL ?? "")
        if let image = memory[identity] { touch(identity); return image }
        if track.artworkURL == nil, let old = cachedImage(for: track.id) {
            storeMemory(old, key: identity)
            return old
        }
        return await image(key: identity, targetSize: CGSize(width: 900, height: 900)) {
            try? await api.coverData(for: track)
        }
    }

    func image(for album: MusicAlbum, api: LemonAPIClient? = nil) async -> UIImage? {
        await image(key: "album:\(album.id)", remoteURL: album.artworkURL, api: api)
    }

    func image(key: String, remoteURL: String?, api: LemonAPIClient? = nil) async -> UIImage? {
        guard let rawURL = remoteURL, let url = URL(string: rawURL) else { return nil }
        let digest = SHA256.hash(data: Data(rawURL.utf8)).map { String(format: "%02x", $0) }.joined()
        return await image(key: "\(key).\(digest)", targetSize: CGSize(width: 600, height: 600)) {
            if let api { return await api.remoteCoverData(rawURL) }
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
        if let image = cachedImage(for: key) {
            storeMemory(image, key: key)
            return image
        }
        if let inflight = inflight[key] { return await inflight.value }
        if let failedAt = failures[key], Date().timeIntervalSince(failedAt) < 60 { return nil }

        let generation = generation
        let task = Task<UIImage?, Never> {
            guard let data = await loader(),
                  let image = UIImage(data: data)?.preparingThumbnail(of: targetSize),
                  !Task.isCancelled, self.generation == generation else { return nil }
            let encoded = image.jpegData(compressionQuality: 0.88) ?? data
            try? encoded.write(to: diskURL, options: .atomic)
            return image
        }
        inflight[key] = task
        let image = await task.value
        guard self.generation == generation else { return nil }
        inflight[key] = nil
        if let image { failures[key] = nil; storeMemory(image, key: key) }
        else if !task.isCancelled { failures[key] = Date() }
        return image
    }

    func cancelLoad(for track: MusicTrack) {
        inflight[track.id + "." + digest(track.artworkURL ?? "")]?.cancel()
    }

    func clear() {
        generation = UUID()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        failures.removeAll()
        memory.removeAll()
        accessOrder.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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
        directory.appendingPathComponent(digest(key) + ".jpg")
    }

    private func cachedImage(for key: String) -> UIImage? {
        let url = fileURL(for: key)
        if let image = UIImage(contentsOfFile: url.path) { return image }
        let safe = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        guard safe.utf8.count + 4 <= 255 else { return nil }
        let legacy = directory.appendingPathComponent(safe + ".jpg")
        guard let image = UIImage(contentsOfFile: legacy.path) else { return nil }
        try? FileManager.default.moveItem(at: legacy, to: url)
        return image
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
