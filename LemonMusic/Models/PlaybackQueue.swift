import Foundation

nonisolated enum PlaybackMode: String, Codable, CaseIterable, Sendable {
    case sequential, shuffled, repeatOne

    var title: String {
        switch self {
        case .sequential: "顺序播放"
        case .shuffled: "随机播放"
        case .repeatOne: "单曲循环"
        }
    }

    var symbol: String {
        switch self {
        case .sequential: "repeat"
        case .shuffled: "shuffle"
        case .repeatOne: "repeat.1"
        }
    }

    var next: Self {
        switch self {
        case .sequential: .shuffled
        case .shuffled: .repeatOne
        case .repeatOne: .sequential
        }
    }
}

// Occurrence IDs keep repeated songs and queue edits intact across mode changes.
nonisolated struct PlaybackQueue: Codable, Sendable {
    struct Entry: Codable, Sendable, Identifiable {
        var id = UUID()
        let track: MusicTrack
    }

    private(set) var original: [Entry] = []
    private(set) var ordered: [Entry] = []
    private(set) var index = 0
    private(set) var mode: PlaybackMode = .sequential

    var tracks: [MusicTrack] { ordered.map(\.track) }
    var current: Entry? { ordered.indices.contains(index) ? ordered[index] : nil }

    mutating func replace(with tracks: [MusicTrack], selecting track: MusicTrack) {
        replace(with: tracks, selectingAt: tracks.firstIndex(of: track) ?? 0)
    }

    mutating func replace(with tracks: [MusicTrack], selectingAt selectedIndex: Int) {
        original = tracks.map { Entry(track: $0) }
        ordered = original
        index = tracks.indices.contains(selectedIndex) ? selectedIndex : 0
        if mode == .shuffled { shuffleKeepingCurrent() }
    }

    mutating func select(_ track: MusicTrack) -> Bool {
        guard let selected = ordered.firstIndex(where: { $0.track == track }) else { return false }
        index = selected
        return true
    }

    mutating func select(entryID: UUID) -> Bool {
        guard let selected = ordered.firstIndex(where: { $0.id == entryID }) else { return false }
        index = selected
        return true
    }

    mutating func setMode(_ value: PlaybackMode) {
        let currentID = current?.id
        mode = value
        if value == .shuffled {
            shuffleKeepingCurrent()
        } else {
            ordered = original
            index = ordered.firstIndex(where: { $0.id == currentID }) ?? 0
        }
    }

    mutating func advance(natural: Bool) {
        guard !ordered.isEmpty else { return }
        if natural, mode == .repeatOne { return }
        if index + 1 < ordered.count {
            index += 1
        } else if mode == .shuffled {
            let last = current?.track.id
            ordered.shuffle()
            if ordered.count > 1, ordered.first?.track.id == last,
               let different = ordered.firstIndex(where: { $0.track.id != last }) {
                ordered.swapAt(0, different)
            }
            index = 0
        } else {
            index = 0
        }
    }

    mutating func retreat() {
        guard !ordered.isEmpty else { return }
        index = (index - 1 + ordered.count) % ordered.count
    }

    mutating func append(_ tracks: [MusicTrack]) {
        let entries = tracks.map { Entry(track: $0) }
        original.append(contentsOf: entries)
        ordered.append(contentsOf: entries)
    }

    mutating func insertNext(_ track: MusicTrack) {
        let entry = Entry(track: track)
        let originalIndex = original.firstIndex(where: { $0.id == current?.id }).map { $0 + 1 } ?? original.count
        original.insert(entry, at: originalIndex)
        ordered.insert(entry, at: min(index + 1, ordered.count))
    }

    mutating func remove(at offsets: IndexSet) {
        let currentID = current?.id
        let removed = Set(offsets.compactMap { ordered.indices.contains($0) ? ordered[$0].id : nil })
            .subtracting(currentID.map { [$0] } ?? [])
        original.removeAll { removed.contains($0.id) }
        ordered.removeAll { removed.contains($0.id) }
        index = ordered.firstIndex(where: { $0.id == currentID }) ?? 0
    }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        let currentID = current?.id
        let moving = offsets.sorted().compactMap { ordered.indices.contains($0) ? ordered[$0] : nil }
        let movingIDs = Set(moving.map(\.id))
        let adjustment = offsets.filter { $0 < destination }.count
        ordered.removeAll { movingIDs.contains($0.id) }
        ordered.insert(contentsOf: moving, at: min(max(0, destination - adjustment), ordered.count))
        if mode == .shuffled {
            original.removeAll { movingIDs.contains($0.id) }
            let nextID = ordered.dropFirst(min(max(0, destination - adjustment) + moving.count, ordered.count)).first?.id
            let target = original.firstIndex(where: { $0.id == nextID }) ?? original.count
            original.insert(contentsOf: moving, at: target)
        } else {
            original = ordered
        }
        index = ordered.firstIndex(where: { $0.id == currentID }) ?? 0
    }

    private mutating func shuffleKeepingCurrent() {
        guard let selected = current else { ordered = original.shuffled(); index = 0; return }
        ordered = [selected] + original.filter { $0.id != selected.id }.shuffled()
        index = 0
    }
}
