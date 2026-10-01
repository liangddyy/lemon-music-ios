import Testing
@testable import LemonMusic

@MainActor
struct CacheStoreTests {
    @Test func staleWhileRevalidateKeepsExpiredPayloadReadable() throws {
        let store = try CacheStore(inMemory: true)
        store.save(["cached"], for: "key", ttl: -1)
        let stale: [String]? = store.value([String].self, for: "key", allowExpired: true)
        let fresh: [String]? = store.value([String].self, for: "key", allowExpired: false)
        #expect(stale == ["cached"])
        #expect(fresh == nil)
    }
}

