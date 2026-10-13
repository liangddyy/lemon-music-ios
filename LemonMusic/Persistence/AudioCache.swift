// Derived from Cassette, licensed under MPL-2.0.

import AudioStreaming
import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class AudioCache {
    static let sizeOptions: [Int64] = [512, 1_024, 2_048, 5_120, 10_240].map { $0 * 1_024 * 1_024 }
    static let defaultMaxBytes: Int64 = 2_048 * 1_024 * 1_024
    static func sizeTitle(_ bytes: Int64) -> String {
        bytes == 512 * 1_024 * 1_024 ? "512 MB" : "\(bytes / (1_024 * 1_024 * 1_024)) GB"
    }

    private let container: ModelContainer
    private let directory: URL
    let streamCache: ProgressiveAudioCache
    private let defaultsKey = "lemon.audioCache.maxBytes"
    private let defaults: UserDefaults

    var onStreamingProgress: ((String, Int64, Int64) -> Void)?
    var onStreamingCompleted: ((String) -> Void)?
    var onChange: (() -> Void)?
    var protectedKeys: Set<String> = []
    var playingKey: String?

    enum StorageError: LocalizedError {
        case capacity
        var errorDescription: String? { "缓存空间不足，请调整缓存上限或清理缓存后重试" }
    }

    var maxBytes: Int64 {
        didSet {
            defaults.set(NSNumber(value: maxBytes), forKey: defaultsKey)
            evictIfNeeded(protectedKey: playingKey)
        }
    }

    var automaticCachingEnabled: Bool {
        didSet {
            defaults.set(automaticCachingEnabled, forKey: "lemon.audioCache.automatic")
            streamCache.setAutomaticCachingEnabled(automaticCachingEnabled)
            onChange?()
        }
    }

    init(container: ModelContainer, root: URL? = nil, defaults: UserDefaults = .standard) {
        self.container = container
        self.defaults = defaults
        maxBytes = (defaults.object(forKey: "lemon.audioCache.maxBytes") as? NSNumber)?.int64Value ?? Self.defaultMaxBytes
        automaticCachingEnabled = defaults.object(forKey: "lemon.audioCache.automatic") as? Bool ?? true
        let root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lemon-music", isDirectory: true)
        directory = root.appendingPathComponent("audio", isDirectory: true)
        streamCache = ProgressiveAudioCache(directory: root.appendingPathComponent("audio-partial", isDirectory: true))
        streamCache.setAutomaticCachingEnabled(automaticCachingEnabled)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        streamCache.onProgress = { [weak self] key, downloaded, total in
            Task { @MainActor in
                self?.evictIfNeeded(protectedKey: self?.playingKey)
                self?.onStreamingProgress?(key, downloaded, total)
            }
        }
        streamCache.onComplete = { [weak self] completion in
            Task { @MainActor in self?.finalize(completion) }
        }
    }

    func cachedURL(for key: String, touching: Bool = true) -> URL? {
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
        if touching {
            entry.lastAccessedAt = Date()
            try? context.save()
        }
        return url
    }

    func availableCache(
        for track: MusicTrack, touching: Bool = true, smooth: Bool? = nil
    ) -> (key: String, url: URL)? {
        if let smooth, track.locator.kind == .local {
            let key = AudioVariant.key(for: track, quality: nil, smooth: smooth)
            return cachedURL(for: key, touching: touching).map { (key, $0) }
        }
        if let url = cachedURL(for: track.id, touching: touching) { return (track.id, url) }
        let prefix = track.id + (track.locator.kind == .online ? "|quality:" : "|format:")
        let records = (try? container.mainContext.fetch(FetchDescriptor<AudioCacheEntry>(
            predicate: #Predicate { $0.key.starts(with: prefix) },
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        ))) ?? []
        for entry in records {
            if let url = cachedURL(for: entry.key, touching: touching) { return (entry.key, url) }
        }
        return nil
    }

    func storeDownloadedFile(
        at temporaryURL: URL,
        key: String,
        mimeType: String,
        expectedByteCount: Int64? = nil,
        protectedKey: String?,
        requiresCapacity: Bool = false
    ) throws -> URL {
        let resource = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(resource.fileSize ?? 0)
        guard size > 1_024 else { throw URLError(.cannotDecodeContentData) }
        if let expectedByteCount, expectedByteCount > 0, size != expectedByteCount {
            throw URLError(.cannotDecodeContentData)
        }
        if requiresCapacity {
            try Self.validateAudioFile(at: temporaryURL, mimeType: mimeType)
            try makeRoom(for: size, replacing: key)
        }

        let fileName = safeFileName(for: key) + "." + fileExtension(for: mimeType)
        let destination = directory.appendingPathComponent(fileName)
        let staging = directory.appendingPathComponent(".download-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: temporaryURL, to: staging)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

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
        try context.save()
        evictIfNeeded(protectedKey: protectedKey)
        onChange?()
        return destination
    }

    func makeRoom(for byteCount: Int64, replacing key: String) throws {
        let context = container.mainContext
        let records = (try? context.fetch(FetchDescriptor<AudioCacheEntry>(
            sortBy: [SortDescriptor(\.lastAccessedAt)]
        ))) ?? []
        var total = usedBytes() - (records.first(where: { $0.key == key })?.byteCount ?? 0)
            - Int64(streamCache.cachedByteCount(for: key))
        let protected = protectedKeys.union(playingKey.map { [$0] } ?? []).union([key])
        guard byteCount <= maxBytes else { throw StorageError.capacity }
        let protectedTotal = records.filter { protected.contains($0.key) && $0.key != key }.reduce(0) { $0 + $1.byteCount }
            + protected.filter { $0 != key }.reduce(0) { $0 + Int64(streamCache.cachedByteCount(for: $1)) }
        guard protectedTotal + byteCount <= maxBytes else { throw StorageError.capacity }
        for entry in records where total + byteCount > maxBytes && !protected.contains(entry.key) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.relativePath))
            total -= entry.byteCount
            context.delete(entry)
        }
        try context.save()
        guard total + byteCount <= maxBytes else { throw StorageError.capacity }
    }

    nonisolated static func validateAudioFile(at url: URL, mimeType: String) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let prefix = try file.read(upToCount: 64) ?? Data()
        let bytes = Array(prefix)
        let signature = String(data: prefix.prefix(4), encoding: .ascii)
        let mp4 = bytes.count >= 8 && String(data: prefix.subdata(in: 4..<8), encoding: .ascii) == "ftyp"
        let frame = bytes.count >= 2 && bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0
        guard ["RIFF", "fLaC", "OggS"].contains(signature ?? "")
                || prefix.starts(with: Data("ID3".utf8)) || mp4 || frame else {
            throw URLError(.cannotDecodeContentData)
        }
    }

    func remove(for key: String) {
        streamCache.remove(for: key)
        let context = container.mainContext
        var descriptor = FetchDescriptor<AudioCacheEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.relativePath))
        context.delete(entry)
        try? context.save()
        onChange?()
    }

    func usedBytes() -> Int64 {
        let records = (try? container.mainContext.fetch(FetchDescriptor<AudioCacheEntry>())) ?? []
        return records.reduce(0) { $0 + $1.byteCount } + streamCache.usedBytes()
    }

    func partialProgress(for key: String) -> (downloaded: Int64, total: Int64)? {
        streamCache.progress(for: key)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        streamCache.clear()
        try? container.mainContext.delete(model: AudioCacheEntry.self)
        try? container.mainContext.save()
    }

    func enforceLimit(protectedKey: String? = nil) { evictIfNeeded(protectedKey: protectedKey) }

    private func evictIfNeeded(protectedKey: String?) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<AudioCacheEntry>(sortBy: [SortDescriptor(\.lastAccessedAt)])
        var entries = (try? context.fetch(descriptor)) ?? []
        var fullTotal = entries.reduce(0) { $0 + $1.byteCount }
        let partialTotal = streamCache.usedBytes()
        guard fullTotal + partialTotal > maxBytes else { return }

        for entry in entries where fullTotal + partialTotal > maxBytes {
            guard entry.key != protectedKey, entry.key != playingKey, !protectedKeys.contains(entry.key) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.relativePath))
            fullTotal -= entry.byteCount
            context.delete(entry)
        }
        try? context.save()
        streamCache.evict(
            toFit: max(0, maxBytes - fullTotal),
            protectedKey: protectedKey ?? playingKey,
            protectedKeys: protectedKeys
        )
        entries.removeAll()
    }

    private func finalize(_ completion: ProgressiveAudioCache.Completion) {
        do {
            _ = try storeDownloadedFile(
                at: completion.url,
                key: completion.key,
                mimeType: completion.mimeType,
                expectedByteCount: completion.byteCount,
                protectedKey: completion.key
            )
            streamCache.didFinalize(key: completion.key, success: true)
            onStreamingCompleted?(completion.key)
        } catch {
            streamCache.didFinalize(key: completion.key, success: false)
        }
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

nonisolated final class ProgressiveAudioCache: AudioStreamCache, @unchecked Sendable {
    struct Completion: Sendable {
        let key: String
        let url: URL
        let mimeType: String
        let byteCount: Int64
    }

    private struct Metadata: Codable {
        let key: String
        var totalLength: Int
        var mimeType: String
        var headerLength: Int
        var remoteDataOffset: Int
        var updatedAt: Date
    }

    private let directory: URL
    private let lock = NSLock()
    private var reportedPercent: [String: Int] = [:]
    private var finalizing: Set<String> = []
    private var enabledKeys: Set<String> = []
    private var automaticCachingEnabled = true

    var onProgress: ((String, Int64, Int64) -> Void)?
    var onComplete: ((Completion) -> Void)?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func setAutomaticCachingEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        automaticCachingEnabled = enabled
    }

    func configure(
        key: String,
        totalLength: Int,
        mimeType: String?,
        headerLength: Int,
        remoteDataOffset: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        enabledKeys.insert(key)

        var metadata = loadMetadata(for: key) ?? Metadata(
            key: key,
            totalLength: totalLength,
            mimeType: mimeType ?? "application/octet-stream",
            headerLength: headerLength,
            remoteDataOffset: remoteDataOffset,
            updatedAt: Date()
        )
        let incompatible = (metadata.totalLength > 0 && totalLength > 0 && metadata.totalLength != totalLength)
            || metadata.headerLength != headerLength
            || metadata.remoteDataOffset != remoteDataOffset
        if incompatible {
            try? FileManager.default.removeItem(at: dataURL(for: key))
            reportedPercent[key] = nil
            finalizing.remove(key)
        }
        if totalLength > 0 { metadata.totalLength = totalLength }
        if let mimeType, !mimeType.isEmpty { metadata.mimeType = mimeType }
        metadata.headerLength = headerLength
        metadata.remoteDataOffset = remoteDataOffset
        metadata.updatedAt = Date()
        saveMetadata(metadata)
    }

    func cachedByteCount(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return fileSize(at: dataURL(for: key))
    }

    func totalByteCount(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return loadMetadata(for: key)?.totalLength ?? 0
    }

    func data(for key: String, offset: Int, length: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let url = dataURL(for: key)
        guard offset >= 0, length > 0, fileSize(at: url) > offset,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length)
        } catch {
            return nil
        }
    }

    func store(data: Data, at offset: Int, for key: String) {
        guard !data.isEmpty else { return }
        var progress: (Int64, Int64)?

        lock.lock()
        guard automaticCachingEnabled, enabledKeys.contains(key) else {
            lock.unlock()
            return
        }
        let url = dataURL(for: key)
        let currentSize = fileSize(at: url)
        guard offset <= currentSize else {
            lock.unlock()
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let overlap = max(0, currentSize - offset)
        if overlap < data.count,
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(currentSize))
                try handle.write(contentsOf: data.dropFirst(overlap))
                if var metadata = loadMetadata(for: key) {
                    metadata.updatedAt = Date()
                    saveMetadata(metadata)
                    let downloaded = Int64(fileSize(at: url))
                    let total = Int64(metadata.totalLength)
                    if total > 0 {
                        let percent = min(100, Int(downloaded * 100 / total))
                        if reportedPercent[key] != percent {
                            reportedPercent[key] = percent
                            progress = (downloaded, total)
                        }
                    }
                }
            } catch {
                // Keep the previous contiguous prefix if appending fails.
            }
        }
        lock.unlock()

        if let progress { onProgress?(key, progress.0, progress.1) }
    }

    func complete(key: String) {
        var completion: Completion?
        lock.lock()
        if automaticCachingEnabled, enabledKeys.contains(key), !finalizing.contains(key), let metadata = loadMetadata(for: key) {
            let size = fileSize(at: dataURL(for: key))
            if metadata.totalLength > 0, size == metadata.totalLength {
                finalizing.insert(key)
                completion = Completion(
                    key: key,
                    url: dataURL(for: key),
                    mimeType: metadata.mimeType,
                    byteCount: Int64(size)
                )
            }
        }
        lock.unlock()
        if let completion { onComplete?(completion) }
    }

    func progress(for key: String) -> (downloaded: Int64, total: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let metadata = loadMetadata(for: key), metadata.totalLength > 0 else { return nil }
        let downloaded = Int64(fileSize(at: dataURL(for: key)))
        guard downloaded > 0 else { return nil }
        return (downloaded, Int64(metadata.totalLength))
    }

    func didFinalize(key: String, success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        finalizing.remove(key)
        if success {
            try? FileManager.default.removeItem(at: metadataURL(for: key))
            reportedPercent[key] = nil
            enabledKeys.remove(key)
        } else if !FileManager.default.fileExists(atPath: dataURL(for: key).path) {
            try? FileManager.default.removeItem(at: metadataURL(for: key))
        }
    }

    func remove(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: dataURL(for: key))
        try? FileManager.default.removeItem(at: metadataURL(for: key))
        reportedPercent[key] = nil
        finalizing.remove(key)
        enabledKeys.remove(key)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reportedPercent.removeAll()
        finalizing.removeAll()
        enabledKeys.removeAll()
    }

    func usedBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return Int64(dataFiles().reduce(0) { $0 + fileSize(at: $1) })
    }

    func evict(toFit allowedBytes: Int64, protectedKey: String?, protectedKeys: Set<String> = []) {
        lock.lock()
        defer { lock.unlock() }
        var entries = metadataFiles().compactMap { url -> (Metadata, URL)? in
            guard let data = try? Data(contentsOf: url),
                  let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { return nil }
            return (metadata, url)
        }.sorted { $0.0.updatedAt < $1.0.updatedAt }
        var total = Int64(dataFiles().reduce(0) { $0 + fileSize(at: $1) })
        while total > allowedBytes, !entries.isEmpty {
            let entry = entries.removeFirst()
            guard entry.0.key != protectedKey, !protectedKeys.contains(entry.0.key),
                  !finalizing.contains(entry.0.key) else { continue }
            let dataURL = self.dataURL(for: entry.0.key)
            total -= Int64(fileSize(at: dataURL))
            try? FileManager.default.removeItem(at: dataURL)
            try? FileManager.default.removeItem(at: entry.1)
            reportedPercent[entry.0.key] = nil
            enabledKeys.remove(entry.0.key)
        }
    }

    private func loadMetadata(for key: String) -> Metadata? {
        guard let data = try? Data(contentsOf: metadataURL(for: key)) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private func saveMetadata(_ metadata: Metadata) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL(for: metadata.key), options: .atomic)
    }

    private func fileSize(at url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func dataFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "part" }
    }

    private func metadataFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private func dataURL(for key: String) -> URL {
        directory.appendingPathComponent(safeFileName(for: key) + ".part")
    }

    private func metadataURL(for key: String) -> URL {
        directory.appendingPathComponent(safeFileName(for: key) + ".json")
    }

    private func safeFileName(for key: String) -> String {
        Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
