// Derived from Cassette, licensed under MPL-2.0.

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

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lemon-music/artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        garbageCollect()
    }

    func image(for track: MusicTrack, api: LemonAPIClient) async -> UIImage? {
        if let image = memory[track.id] { touch(track.id); return image }
        let diskURL = fileURL(for: track.id)
        if let image = UIImage(contentsOfFile: diskURL.path) {
            storeMemory(image, key: track.id)
            return image
        }
        if let inflight = inflight[track.id] { return await inflight.value }

        let task = Task<UIImage?, Never> {
            guard let data = try? await api.coverData(for: track),
                  let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 900, height: 900)) else { return nil }
            let encoded = image.jpegData(compressionQuality: 0.88) ?? data
            try? encoded.write(to: diskURL, options: .atomic)
            return image
        }
        inflight[track.id] = task
        let image = await task.value
        inflight[track.id] = nil
        if let image { storeMemory(image, key: track.id) }
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

