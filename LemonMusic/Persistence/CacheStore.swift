// Derived from Cassette, licensed under MPL-2.0.

import Foundation
import SwiftData

@MainActor
final class CacheStore {
    let container: ModelContainer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(inMemory: Bool = false) throws {
        let schema = Schema([CacheEntry.self, AudioCacheEntry.self])
        let configuration = ModelConfiguration("lemon-music", schema: schema, isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: schema, configurations: configuration)
    }

    func value<T: Decodable>(_ type: T.Type, for key: String, allowExpired: Bool = true) -> T? {
        let context = container.mainContext
        var descriptor = FetchDescriptor<CacheEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first else { return nil }
        if !allowExpired, let expiry = entry.expiresAt, expiry < Date() { return nil }
        return try? decoder.decode(type, from: entry.payload)
    }

    func save<T: Encodable>(_ value: T, for key: String, ttl: TimeInterval? = nil) {
        guard let data = try? encoder.encode(value) else { return }
        let context = container.mainContext
        var descriptor = FetchDescriptor<CacheEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        let expiry = ttl.map { Date().addingTimeInterval($0) }
        if let entry = try? context.fetch(descriptor).first {
            entry.payload = data
            entry.updatedAt = Date()
            entry.expiresAt = expiry
        } else {
            context.insert(CacheEntry(key: key, payload: data, expiresAt: expiry))
        }
        try? context.save()
    }

    func isFresh(_ key: String) -> Bool {
        let context = container.mainContext
        var descriptor = FetchDescriptor<CacheEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first else { return false }
        return entry.expiresAt.map { $0 > Date() } ?? true
    }

    func clearMetadata() {
        let context = container.mainContext
        try? context.delete(model: CacheEntry.self)
        try? context.save()
    }

    func removeValues(prefix: String) {
        let context = container.mainContext
        guard let entries = try? context.fetch(FetchDescriptor<CacheEntry>()) else { return }
        for entry in entries where entry.key.hasPrefix(prefix) { context.delete(entry) }
        try? context.save()
    }

    func clearAll() {
        let context = container.mainContext
        try? context.delete(model: CacheEntry.self)
        try? context.delete(model: AudioCacheEntry.self)
        try? context.save()
    }
}
