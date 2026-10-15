import Foundation

nonisolated struct CarPlayPagination {
    let range: Range<Int>
    let page: Int
    let pageCount: Int

    init(count: Int, page: Int, maximumItems: Int) {
        // Reserve room for play-all, previous/next page, and library loading/retry.
        let size = max(1, min(100, maximumItems - 4))
        let count = max(0, count)
        pageCount = max(1, (count + size - 1) / size)
        self.page = min(max(0, page), pageCount - 1)
        let start = self.page * size
        range = start..<min(start + size, count)
    }

    var hasPrevious: Bool { page > 0 }
    var hasNext: Bool { page + 1 < pageCount }
}
