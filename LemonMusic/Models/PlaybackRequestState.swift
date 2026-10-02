import Foundation

nonisolated struct PlaybackRequestState {
    private(set) var id: String?

    mutating func begin() -> String {
        let nextID = UUID().uuidString
        id = nextID
        return nextID
    }

    func isCurrent(_ candidate: String) -> Bool { id == candidate }

    mutating func consumeEnd(for candidate: String) -> Bool {
        guard isCurrent(candidate) else { return false }
        id = nil
        return true
    }
}
