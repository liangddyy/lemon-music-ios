import Foundation
import Network
import Observation
import UIKit

nonisolated enum CacheItemState: String, Codable, Sendable {
    case waiting, downloading, waitingPlayback, waitingWiFi, paused, completed, failed, cancelled
    var title: String {
        switch self {
        case .waiting: "等待缓存"
        case .downloading: "缓存中"
        case .waitingPlayback: "边播边缓存"
        case .waitingWiFi: "等待 Wi-Fi"
        case .paused: "已暂停"
        case .completed: "已缓存"
        case .failed: "失败"
        case .cancelled: "已取消"
        }
    }
}

nonisolated struct CollectionCacheItem: Codable, Identifiable, Sendable {
    var id = UUID()
    let track: MusicTrack
    var resolved: MusicTrack?
    var state: CacheItemState = .waiting
    var progress: Double = 0
    var error: String?
    var taskID: Int?
    var transferID: UUID?
    var resumeData: Data? = nil
    var suspending: Bool?
    var quality: String?
    var smooth: Bool? = nil
    var cacheKey: String { AudioVariant.key(for: resolved ?? track, quality: quality, smooth: smooth ?? false) }

    // Opaque resume data may include authenticated requests; persist it only in Keychain.
    private enum CodingKeys: String, CodingKey {
        case id, track, resolved, state, progress, error, taskID, transferID, suspending, quality, smooth
    }

    var resumeStorageKey: String { "cache-resume.\(id.uuidString)" }
}

nonisolated struct CollectionCacheBatch: Codable, Sendable {
    var id = UUID()
    let key: String
    let title: String
    let account: String
    var allowsCellular: Bool
    var paused = false
    var cancelled = false
    var items: [CollectionCacheItem]
    var completedCount: Int { items.filter { $0.state == .completed }.count }
    var isFinished: Bool { completedCount == items.count }
    var summary: String {
        if cancelled { return "已取消 · \(completedCount)/\(items.count)" }
        if isFinished { return "已缓存 \(items.count) 首" }
        if paused { return "已暂停 · \(completedCount)/\(items.count)" }
        return "缓存 \(completedCount)/\(items.count)"
    }
}

nonisolated struct CacheTransferTag: Codable, Sendable {
    let account: String
    let key: String
    let batchID: UUID
    let itemID: UUID
    let transferID: UUID
    let allowsCellular: Bool
    var quality: String? = nil
    var smooth: Bool? = nil

    func matchesVariant(of item: CollectionCacheItem) -> Bool {
        quality == item.quality && smooth == item.smooth
    }
}

@MainActor enum BackgroundCacheEvents {
    static var completionHandlers: [String: () -> Void] = [:]
    static func finish(_ identifier: String) {
        completionHandlers.removeValue(forKey: identifier)?()
    }
}

@Observable @MainActor
final class CollectionCacheCoordinator {
    nonisolated static let sessionIdentifier = "top.btop.music.collection-cache"
    private(set) var batches: [String: CollectionCacheBatch] = [:]
    private(set) var isCellular = false
    private(set) var isConnected = true
    var preferredTrack: ((MusicTrack) async -> MusicTrack)?
    private let api: LemonAPIClient
    private let audioCache: AudioCache
    private let store: CacheStore
    private let audioPolicy: AudioPlaybackPolicy?
    private var account: String?
    private var active = false
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private var restoring = false
    @ObservationIgnored private let bridge: CacheDownloadDelegate
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let resumeKeychain = KeychainStore()
    @ObservationIgnored private var persistedResume: [UUID: Data] = [:]

    init(
        api: LemonAPIClient, audioCache: AudioCache, store: CacheStore,
        background: Bool = true, monitorNetwork: Bool = true,
        sessionIdentifier: String = CollectionCacheCoordinator.sessionIdentifier,
        audioPolicy: AudioPlaybackPolicy? = nil
    ) {
        self.api = api
        self.audioCache = audioCache
        self.store = store
        self.audioPolicy = audioPolicy
        let bridge = CacheDownloadDelegate()
        self.bridge = bridge
        let configuration = background
            ? URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
            : URLSessionConfiguration.ephemeral
        configuration.sessionSendsLaunchEvents = background
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: bridge, delegateQueue: .main)
        bridge.coordinator = self
        audioCache.onChange = { [weak self] in self?.pump() }
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let cellular = path.usesInterfaceType(.cellular) || path.isExpensive
            Task { @MainActor in self.networkChanged(connected: connected, cellular: cellular) }
        }
        if monitorNetwork { monitor.start(queue: DispatchQueue(label: "lemon.cache-network")) }
    }

    func configure(account: String, activate: Bool = true) {
        if self.account == account {
            active = activate
            pump()
            return
        }
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        self.account = account
        active = activate
        batches = store.value([String: CollectionCacheBatch].self, for: "cache-batches.\(account)") ?? [:]
        persistedResume.removeAll()
        for key in batches.keys {
            for index in batches[key]?.items.indices ?? 0..<0 {
                guard let item = batches[key]?.items[index],
                      let text = resumeKeychain.get(item.resumeStorageKey),
                      let data = Data(base64Encoded: text) else { continue }
                batches[key]?.items[index].resumeData = data
                persistedResume[item.id] = data
            }
        }
        restoring = true
        let generation = generation
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == generation else { return }
                var live = Set<UUID>()
                for task in tasks {
                    guard let tag = Self.tag(for: task), self.accepts(tag) else { task.cancel(); continue }
                    live.insert(tag.transferID)
                    self.update(tag) { $0.taskID = task.taskIdentifier }
                    if self.batches[tag.key]?.paused == true || self.batches[tag.key]?.cancelled == true {
                        self.pauseTransfer(task, tag: tag, state: .paused)
                    }
                }
                for key in Array(self.batches.keys) {
                    for index in self.batches[key]?.items.indices ?? 0..<0 {
                        guard let item = self.batches[key]?.items[index],
                              let transfer = item.transferID, !live.contains(transfer) else { continue }
                        self.batches[key]?.items[index].taskID = nil
                        self.batches[key]?.items[index].transferID = nil
                        self.batches[key]?.items[index].suspending = false
                        if item.state == .downloading { self.batches[key]?.items[index].state = .waiting }
                    }
                }
                self.restoring = false
                self.persist()
                self.pump()
            }
        }
    }

    func start(key: String, title: String, tracks: [MusicTrack], allowsCellular: Bool) {
        guard let account else { return }
        if let existing = batches[key], !existing.cancelled, !existing.isFinished {
            resume(key: key, allowsCellular: allowsCellular)
            return
        }
        var seen = Set<String>()
        let items = tracks.filter { seen.insert($0.id).inserted }.map { CollectionCacheItem(track: $0) }
        batches[key] = CollectionCacheBatch(key: key, title: title, account: account, allowsCellular: allowsCellular, items: items)
        persist()
        pump()
    }

    func resume(key: String, allowsCellular: Bool? = nil) {
        guard var batch = batches[key], !batch.cancelled else { return }
        batch.paused = false
        if let allowsCellular {
            if allowsCellular && !batch.allowsCellular {
                for index in batch.items.indices { batch.items[index].resumeData = nil }
            }
            batch.allowsCellular = allowsCellular
        }
        for index in batch.items.indices where batch.items[index].state == .failed || batch.items[index].state == .paused {
            batch.items[index].state = .waiting
            batch.items[index].error = nil
        }
        batches[key] = batch
        persist()
        pump()
    }

    func pause(key: String) {
        batches[key]?.paused = true
        for index in batches[key]?.items.indices ?? 0..<0 where batches[key]?.items[index].state == .waiting {
            batches[key]?.items[index].state = .paused
        }
        pauseTasks(key: key, state: .paused)
        persist()
        protectTargets()
    }

    func cancel(key: String) {
        batches[key]?.cancelled = true
        for index in batches[key]?.items.indices ?? 0..<0 where batches[key]?.items[index].state != .completed {
            batches[key]?.items[index].state = .cancelled
            batches[key]?.items[index].resumeData = nil
            batches[key]?.items[index].taskID = nil
            batches[key]?.items[index].transferID = nil
        }
        pauseTasks(key: key, state: .cancelled)
        persist()
        protectTargets()
    }

    func prepareForLimitChange(to bytes: Int64) {
        guard bytes < audioCache.maxBytes else { return }
        for key in Array(batches.keys) where batches[key]?.isFinished == false && batches[key]?.cancelled == false {
            pause(key: key)
        }
        protectTargets()
    }

    func reset() {
        let oldBatchIDs = Set(batches.values.map(\.id))
        generation = UUID()
        active = false
        preparation?.cancel()
        preparation = nil
        for key in Array(batches.keys) { cancel(key: key) }
        batches.removeAll()
        persistedResume.removeAll()
        account = nil
        audioCache.protectedKeys.removeAll()
        session.getAllTasks { tasks in
            for task in tasks where Self.tag(for: task).map({ oldBatchIDs.contains($0.batchID) }) == true { task.cancel() }
        }
    }

    func givePlaybackPriority(to track: MusicTrack) async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let tag = Self.tag(for: task), accepts(tag),
                  let item = item(for: tag), (item.resolved ?? item.track).id == track.id else { continue }
            update(tag) { $0.state = .waitingPlayback; $0.suspending = true }
            let data: Data? = await withCheckedContinuation { continuation in
                guard let download = task as? URLSessionDownloadTask else { task.cancel(); continuation.resume(returning: nil); return }
                download.cancel { data in continuation.resume(returning: data) }
            }
            let compatible = tag.allowsCellular == batches[tag.key]?.allowsCellular
            update(tag) {
                $0.resumeData = compatible ? data : nil; $0.taskID = nil; $0.transferID = nil; $0.suspending = false
            }
        }
        persist()
    }

    func pump() {
        protectTargets()
        guard active, account != nil, !restoring, preparation == nil, isConnected else { return }
        let generation = generation
        preparation = Task { [weak self] in
            guard let self else { return }
            var needsAnotherPass = false
            defer {
                if self.generation == generation {
                    self.preparation = nil
                    if needsAnotherPass { self.pump() }
                }
            }
            for key in self.batches.keys.sorted() {
                guard let batch = self.batches[key], !batch.paused, !batch.cancelled else { continue }
                for index in batch.items.indices {
                    guard self.generation == generation, !Task.isCancelled else { return }
                    guard let item = self.batches[key]?.items[index], item.taskID == nil,
                          item.suspending != true,
                          [.waiting, .waitingPlayback, .waitingWiFi].contains(item.state) else { continue }
                    if self.isCellular && !batch.allowsCellular {
                        self.batches[key]?.items[index].state = .waitingWiFi
                        continue
                    }
                    if self.audioCache.availableCache(for: item.resolved ?? item.track, smooth: self.audioPolicy?.serverSettings.smooth ?? false) != nil {
                        self.batches[key]?.items[index].state = .completed
                        self.batches[key]?.items[index].progress = 1
                        continue
                    }
                    if self.transferCount >= 4 { self.persist(); return }
                    do {
                        let resolved: MusicTrack
                        if let saved = item.resolved { resolved = saved }
                        else { resolved = await self.preferredTrack?(item.track) ?? item.track }
                        guard self.generation == generation, !Task.isCancelled,
                              self.batches[key]?.paused == false, self.batches[key]?.cancelled == false else { continue }
                        self.batches[key]?.items[index].resolved = resolved
                        if self.audioCache.availableCache(for: resolved, smooth: self.audioPolicy?.serverSettings.smooth ?? false) != nil {
                            self.batches[key]?.items[index].state = .completed
                            self.batches[key]?.items[index].progress = 1
                            continue
                        }
                        if self.audioCache.automaticCachingEnabled, AudioVariant.matches(self.audioCache.playingKey, trackID: resolved.id) {
                            self.batches[key]?.items[index].state = .waitingPlayback
                            continue
                        }
                        if self.batches.values.flatMap(\.items).contains(where: {
                            $0.id != item.id && ($0.resolved ?? $0.track).id == resolved.id && $0.taskID != nil
                        }) {
                            continue
                        }
                        if self.isCellular && !batch.allowsCellular {
                            self.batches[key]?.items[index].state = .waitingWiFi
                            continue
                        }
                        let settings = try await self.api.serverPlaybackSettings()
                        guard self.generation == generation, !Task.isCancelled else { return }
                        self.audioPolicy?.applyServerSettings(settings)
                        let smooth = settings.smooth
                        let quality: String?
                        if resolved.locator.kind == .local { quality = nil }
                        else if let override = self.audioPolicy?.qualityOverride { quality = override }
                        else { quality = try await self.api.serverPlayQuality() }
                        if self.batches[key]?.items[index].quality != quality || self.batches[key]?.items[index].smooth != smooth {
                            self.batches[key]?.items[index].resumeData = nil
                        }
                        self.batches[key]?.items[index].quality = quality
                        self.batches[key]?.items[index].smooth = smooth
                        let cacheKey = AudioVariant.key(for: resolved, quality: quality, smooth: smooth)
                        if self.audioCache.availableCache(for: resolved, smooth: smooth) != nil {
                            self.batches[key]?.items[index].state = .completed
                            self.batches[key]?.items[index].progress = 1
                            continue
                        }
                        try self.audioCache.makeRoom(for: 1_024, replacing: cacheKey)
                        var request = try await self.api.audioDownloadRequest(for: resolved, quality: quality, smooth: smooth)
                        guard self.generation == generation, !Task.isCancelled,
                              self.batches[key]?.paused == false, self.batches[key]?.cancelled == false else { continue }
                        if self.audioCache.automaticCachingEnabled, AudioVariant.matches(self.audioCache.playingKey, trackID: resolved.id) {
                            self.batches[key]?.items[index].state = .waitingPlayback
                            continue
                        }
                        if resolved.locator.kind == .online, self.audioPolicy?.qualityOverride == "128k", quality != "128k" {
                            self.batches[key]?.items[index].state = .waiting
                            needsAnotherPass = true
                            return
                        }
                        request.allowsCellularAccess = batch.allowsCellular
                        let task: URLSessionDownloadTask
                        if let data = self.batches[key]?.items[index].resumeData {
                            task = self.session.downloadTask(withResumeData: data)
                        } else {
                            task = self.session.downloadTask(with: request)
                        }
                        let transfer = UUID()
                        let tag = CacheTransferTag(
                            account: batch.account, key: key, batchID: batch.id, itemID: item.id,
                            transferID: transfer, allowsCellular: batch.allowsCellular, quality: quality, smooth: smooth
                        )
                        task.taskDescription = String(data: try JSONEncoder().encode(tag), encoding: .utf8)
                        self.batches[key]?.items[index].taskID = task.taskIdentifier
                        self.batches[key]?.items[index].transferID = transfer
                        self.batches[key]?.items[index].state = .downloading
                        self.batches[key]?.items[index].resumeData = nil
                        self.persist()
                        task.resume()
                    } catch {
                        guard self.generation == generation else { return }
                        self.batches[key]?.items[index].error = error.localizedDescription
                        self.batches[key]?.items[index].state = .failed
                        if error is AudioCache.StorageError { self.pause(key: key) }
                    }
                }
            }
            self.persist()
            self.protectTargets()
        }
    }

    func receivedFile(_ url: URL, task: URLSessionDownloadTask) {
        guard let tag = Self.tag(for: task), accepts(tag), let item = item(for: tag),
              item.state == .downloading, item.suspending != true, tag.matchesVariant(of: item) else { return }
        do {
            guard let response = task.response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let mime = response.mimeType ?? "application/octet-stream"
            guard mime.hasPrefix("audio/") || ["application/octet-stream", "video/mp4", "application/ogg"].contains(mime) else {
                throw URLError(.cannotDecodeContentData)
            }
            let expected = response.statusCode == 200 ? response.expectedContentLength
                : response.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) } ?? -1
            _ = try audioCache.storeDownloadedFile(
                at: url, key: item.cacheKey, mimeType: mime,
                expectedByteCount: expected > 0 ? expected : nil,
                protectedKey: audioCache.playingKey, requiresCapacity: true
            )
            audioCache.streamCache.remove(for: item.cacheKey)
            update(tag) { $0.state = .completed; $0.progress = 1; $0.error = nil; $0.resumeData = nil }
        } catch {
            update(tag) { $0.state = .failed; $0.error = error.localizedDescription }
            if error is AudioCache.StorageError { pause(key: tag.key) }
        }
        update(tag) { $0.taskID = nil; $0.transferID = nil }
        persist()
        pump()
    }

    func completed(task: URLSessionTask, error: Error?) {
        guard let tag = Self.tag(for: task), accepts(tag), let item = item(for: tag) else { return }
        if item.suspending == true || [.paused, .waitingWiFi, .waitingPlayback, .cancelled].contains(item.state) { return }
        update(tag) {
            $0.taskID = nil
            $0.transferID = nil
            if let error {
                $0.state = .failed
                $0.error = error.localizedDescription
                $0.resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            }
        }
        persist()
        pump()
    }

    func progress(task: URLSessionDownloadTask, received: Int64, total: Int64) {
        guard let tag = Self.tag(for: task), total > 0, let item = item(for: tag),
              item.state == .downloading, tag.matchesVariant(of: item) else { return }
        update(tag) { $0.progress = min(1, Double(received) / Double(total)) }
    }

    nonisolated static func tag(for task: URLSessionTask) -> CacheTransferTag? {
        task.taskDescription?.data(using: .utf8).flatMap { try? JSONDecoder().decode(CacheTransferTag.self, from: $0) }
    }

    private var transferCount: Int { batches.values.flatMap(\.items).filter { $0.taskID != nil }.count }

    private func item(for tag: CacheTransferTag) -> CollectionCacheItem? {
        batches[tag.key]?.items.first { $0.id == tag.itemID }
    }

    private func accepts(_ tag: CacheTransferTag) -> Bool {
        account == tag.account && batches[tag.key]?.id == tag.batchID
            && item(for: tag)?.transferID == tag.transferID && batches[tag.key]?.cancelled == false
    }

    private func update(_ tag: CacheTransferTag, _ change: (inout CollectionCacheItem) -> Void) {
        guard accepts(tag), let index = batches[tag.key]?.items.firstIndex(where: { $0.id == tag.itemID }) else { return }
        change(&batches[tag.key]!.items[index])
    }

    func networkChanged(connected: Bool, cellular: Bool) {
        isConnected = connected
        isCellular = cellular
        audioPolicy?.updateNetwork(cellular: cellular, connected: connected)
        if cellular {
            for key in batches.keys where batches[key]?.allowsCellular == false {
                pauseTasks(key: key, state: .waitingWiFi)
            }
        }
        pump()
    }

    private func pauseTasks(key: String, state: CacheItemState) {
        let batchID = batches[key]?.id
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            Task { @MainActor in
                for task in tasks {
                    guard let tag = Self.tag(for: task), tag.key == key, tag.batchID == batchID else { continue }
                    if state == .cancelled { task.cancel(); continue }
                    guard self.accepts(tag) else { continue }
                    if state == .waitingWiFi && (!self.isCellular || self.batches[key]?.allowsCellular == true) { continue }
                    if state == .paused && self.batches[key]?.paused != true { continue }
                    self.pauseTransfer(task, tag: tag, state: state)
                }
            }
        }
    }

    func applyAudioPolicy() {
        guard audioPolicy != nil else { return }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            Task { @MainActor in
                guard let policy = self.audioPolicy else { return }
                for task in tasks {
                    guard let tag = Self.tag(for: task), self.accepts(tag), let item = self.item(for: tag) else { continue }
                    let track = item.resolved ?? item.track
                    let smoothChanged = track.locator.kind == .local
                        && AudioVariant.usesAAC(for: track, smooth: item.smooth ?? false) != AudioVariant.usesAAC(for: track, smooth: policy.serverSettings.smooth)
                    let qualityChanged = track.locator.kind == .online && policy.qualityOverride == "128k" && item.quality != "128k"
                    guard smoothChanged || qualityChanged else { continue }
                    self.update(tag) {
                        if qualityChanged { $0.quality = "128k" }
                        $0.smooth = policy.serverSettings.smooth
                        $0.resumeData = nil
                        $0.progress = 0
                    }
                    self.pauseTransfer(task, tag: tag, state: .waiting)
                }
                self.persist()
                self.pump()
            }
        }
    }

    private func pauseTransfer(_ task: URLSessionTask, tag: CacheTransferTag, state: CacheItemState) {
        update(tag) { $0.state = state; $0.suspending = true }
        guard let download = task as? URLSessionDownloadTask else { task.cancel(); return }
        download.cancel { [weak self] data in
            guard let self else { return }
            Task { @MainActor in
                let compatible = tag.allowsCellular == self.batches[tag.key]?.allowsCellular
                    && self.item(for: tag).map { tag.matchesVariant(of: $0) } == true
                self.update(tag) {
                    $0.resumeData = state == .cancelled || !compatible ? nil : data
                    $0.taskID = nil
                    $0.transferID = nil
                    $0.suspending = false
                }
                self.persist()
                self.pump()
            }
        }
    }

    private func protectTargets() {
        audioCache.protectedKeys = Set(batches.values.filter { !$0.cancelled && !$0.paused && !$0.isFinished }.flatMap { $0.items.map(\.cacheKey) })
    }

    private func persist() {
        guard let account else { return }
        for key in batches.keys {
            for index in batches[key]?.items.indices ?? 0..<0 {
                guard let item = batches[key]?.items[index] else { continue }
                if let data = item.resumeData, persistedResume[item.id] != data {
                    do {
                        try resumeKeychain.set(data.base64EncodedString(), for: item.resumeStorageKey)
                        persistedResume[item.id] = data
                    } catch {
                        batches[key]?.items[index].error = "续传状态未保存，重新打开后将重新缓存"
                    }
                } else if item.resumeData == nil, persistedResume.removeValue(forKey: item.id) != nil {
                    resumeKeychain.delete(item.resumeStorageKey)
                }
            }
        }
        store.save(batches, for: "cache-batches.\(account)")
    }
}

nonisolated final class CacheDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    @MainActor weak var coordinator: CollectionCacheCoordinator?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated { coordinator?.receivedFile(location, task: downloadTask) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated { coordinator?.progress(task: downloadTask, received: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated { coordinator?.completed(task: task, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { BackgroundCacheEvents.finish(session.configuration.identifier ?? "") }
    }
}

final class LemonAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundCacheEvents.completionHandlers[identifier] = completionHandler
    }
}
