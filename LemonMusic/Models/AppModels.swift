// Derived from Cassette, licensed under MPL-2.0.

import Foundation
import SwiftData

@Model
final class CacheEntry {
    @Attribute(.unique) var key: String
    var payload: Data
    var updatedAt: Date
    var expiresAt: Date?

    init(key: String, payload: Data, updatedAt: Date = Date(), expiresAt: Date? = nil) {
        self.key = key
        self.payload = payload
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

@Model
final class AudioCacheEntry {
    @Attribute(.unique) var key: String
    var relativePath: String
    var byteCount: Int64
    var mimeType: String
    var lastAccessedAt: Date

    init(key: String, relativePath: String, byteCount: Int64, mimeType: String, lastAccessedAt: Date = Date()) {
        self.key = key
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.mimeType = mimeType
        self.lastAccessedAt = lastAccessedAt
    }
}

nonisolated struct ServerProfile: Codable, Sendable, Equatable {
    var baseURL: String
    var username: String
    var user: SessionUser?
    var apiPrefix: String?
}
