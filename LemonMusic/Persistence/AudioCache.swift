// Derived from Cassette, licensed under MPL-2.0.

import Foundation
import SwiftData

@MainActor
final class AudioCache {
    static let sizeOptions: [Int64] = [512, 1_024, 2_048, 5_120, 10_240].map { $0 * 1_024 * 1_024 }
    static let defaultMaxBytes: Int64 = 2_048 * 1_024 * 1_024

    private let container: ModelContainer
    private let directory: URL
    private let defaultsKey = "lemon.audioCache.maxBytes"

    var maxBytes: Int64 {
        get {
            let value = UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber
            return value?.int64Value ?? Self.defaultMaxBytes
        }
        set { UserDefaults.standard.set(NSNumber(value: newValue), forKey: defaultsKey) }
    }

    var cacheOverCellular: Bool {
        get { UserDefaults.standard.bool(forKey: "lemon.audioCache.cellular") }
        set { UserDefaults.standard.set(newValue, forKey: "lemon.audioCache.cellular") }
    }

    init(container: ModelContainer) {
        self.container = container
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lemon-music/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cachedURL(for key: String) -> URL? {
        let context = container.mainContext
        var descriptor = FetchDescriptor<AudioCacheEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first else { return nil }
        let url = directory.appendingPathComponent(entry.relativePath)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0, size == entry.byteCount else {
            try? FileManager.default.removeItem(at: url)
            context.delete(entry)
            try? context.save()
            return nil
        }
        entry.lastAccessedAt = Date()
        try? context.save()
        return url
    }

    func storeDownloadedFile(at temporaryURL: URL, key: String, mimeType: String, protectedKey: String?) throws -> URL {
        let resource = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(resource.fileSize ?? 0)
        guard size > 1_024 else { throw URLError(.cannotDecodeContentData) }

        let fileName = safeFileName(for: key) + "." + fileExtension(for: mimeType)
        let destination = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        let context = container.mainContext
        var descriptor = FetchDescriptor<AudioCacheEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let entry = try? context.fetch(descriptor).first {
            if entry.relativePath != fileName {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.relativePath))
            }
            entry.relativePath = fileName
            entry.byteCount = size
            entry.mimeType = mimeType
            entry.lastAccessedAt = Date()
        } else {
            context.insert(AudioCacheEntry(key: key, relativePath: fileName, byteCount: size, mimeType: mimeType))
        }
        try? context.save()
        evictIfNeeded(protectedKey: protectedKey)
        return destination
    }

    func usedBytes() -> Int64 {
        let records = (try? container.mainContext.fetch(FetchDescriptor<AudioCacheEntry>())) ?? []
        return records.reduce(0) { $0 + $1.byteCount }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? container.mainContext.delete(model: AudioCacheEntry.self)
        try? container.mainContext.save()
    }

    func enforceLimit(protectedKey: String? = nil) { evictIfNeeded(protectedKey: protectedKey) }

    private func evictIfNeeded(protectedKey: String?) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<AudioCacheEntry>(sortBy: [SortDescriptor(\.lastAccessedAt)])
        var entries = (try? context.fetch(descriptor)) ?? []
        var total = entries.reduce(0) { $0 + $1.byteCount }
        guard total > maxBytes else { return }

        for entry in entries where total > maxBytes {
            guard entry.key != protectedKey else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.relativePath))
            total -= entry.byteCount
            context.delete(entry)
        }
        try? context.save()
        entries.removeAll()
    }

    private func safeFileName(for key: String) -> String {
        Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case let value where value.contains("flac"): "flac"
        case let value where value.contains("wav"): "wav"
        case let value where value.contains("ogg"): "ogg"
        case let value where value.contains("opus"): "opus"
        case let value where value.contains("aac") || value.contains("mp4") || value.contains("m4a"): "m4a"
        default: "mp3"
        }
    }
}
