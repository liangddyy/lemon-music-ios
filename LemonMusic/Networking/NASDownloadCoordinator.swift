import Foundation
import Observation

@Observable @MainActor
final class NASDownloadCoordinator {
    private(set) var batches: [String: NASBatch] = [:]
    private(set) var submitting: Set<String> = []
    private let api: LemonAPIClient
    private let store: CacheStore
    private var account: String?
    private var generation = UUID()
    private var workers: [String: Task<Void, Never>] = [:]
    private var refreshing = false
    private var lastRefresh = Date.distantPast
    var preferredTrack: ((MusicTrack) async -> MusicTrack)?

    init(api: LemonAPIClient, store: CacheStore) {
        self.api = api
        self.store = store
    }

    func configure(account: String) {
        guard self.account != account else { return }
        reset()
        self.account = account
        batches = store.value([String: NASBatch].self, for: "nas-batches.\(account)") ?? [:]
    }

    func reset() {
        generation = UUID()
        workers.values.forEach { $0.cancel() }
        workers.removeAll()
        batches.removeAll()
        submitting.removeAll()
        account = nil
        refreshing = false
        lastRefresh = .distantPast
    }

    func start(key: String, title: String, tracks: [MusicTrack], quality: NASQuality) {
        guard account != nil, !submitting.contains(key) else { return }
        if let previous = batches[key], !previous.submissionComplete { retry(key: key); return }
        batches[key] = NASBatch(collectionKey: key, title: title, quality: quality, tracks: tracks)
        persist()
        retry(key: key)
    }

    func retry(key: String) {
        guard let batch = batches[key], !batch.submissionComplete, !submitting.contains(key), account != nil else { return }
        let generation = generation
        submitting.insert(key)
        batches[key]?.error = nil
        workers[key] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.submitting.remove(key)
                    self.workers[key] = nil
                    self.persist()
                }
            }
            do {
                while let batch = self.batches[key], !batch.submissionComplete {
                    try Task.checkCancellation()
                    let end = min(batch.cursor + 50, batch.tracks.count)
                    var online: [MusicTrack] = []
                    for track in batch.tracks[batch.cursor..<end] {
                        let preferred = await self.preferredTrack?(track) ?? track
                        guard self.generation == generation, !Task.isCancelled else { return }
                        if preferred.locator.kind == .online { online.append(track) }
                    }
                    let result = online.isEmpty
                        ? NASSubmission(ids: [], skipped: 0)
                        : try await self.api.addDownloads(online, quality: batch.quality, batchID: key)
                    guard self.generation == generation, !Task.isCancelled else { return }
                    self.batches[key]?.cursor = end
                    self.batches[key]?.ids.append(contentsOf: result.ids)
                    self.batches[key]?.skipped += end - batch.cursor - online.count + result.skipped
                    self.persist()
                }
                await self.refresh()
            } catch {
                guard self.generation == generation else { return }
                self.batches[key]?.error = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard account != nil, !batches.isEmpty, !refreshing,
              Date().timeIntervalSince(lastRefresh) >= 2 else { return }
        let generation = generation
        refreshing = true
        lastRefresh = Date()
        defer { if self.generation == generation { refreshing = false } }
        do {
            let tasks = try await api.downloadTasks()
            guard self.generation == generation else { return }
            for key in batches.keys {
                let ids = Set(batches[key]?.ids ?? [])
                let latest = tasks.filter { ids.contains($0.id) }
                let present = Set(latest.map(\.id))
                let retained = (batches[key]?.tasks ?? []).filter { !present.contains($0.id) && $0.status == "completed" }
                batches[key]?.tasks = latest + retained
                if batches[key]?.submissionComplete == true { batches[key]?.error = nil }
            }
            persist()
        } catch {
            guard self.generation == generation else { return }
            for key in batches.keys where batches[key]?.ids.isEmpty == false {
                batches[key]?.error = error.localizedDescription
            }
        }
    }

    private func persist() {
        guard let account else { return }
        store.save(batches, for: "nas-batches.\(account)")
    }
}
