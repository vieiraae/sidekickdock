import Foundation

/// The switcher's index arithmetic, kept apart from the controller so it can be reasoned
/// about — and tested — without a window server, a snapshot or an overlay.
///
/// Every one of these has been a source of off-by-one or wrap-around bugs, which is exactly
/// the kind of thing that is invisible in a screenshot and obvious in a test.
enum SwitcherIndex {

    /// Wraps `index + delta` into `0..<count`, in both directions.
    ///
    /// Swift's `%` keeps the sign of the dividend, so the plain remainder goes negative when
    /// stepping backwards off the front. The double modulo folds it back into range.
    static func wrap(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// Steps the selection through the most-recently-used order.
    ///
    /// `recency` holds indices into the flattened window list, newest first. The selection is
    /// an index into that same list, not a position in `recency`, so it has to be located
    /// before it can be moved. A selection that is not present — which should not happen —
    /// falls back to spatial order rather than refusing to move.
    static func stepInRecency(selection: Int, by delta: Int, recency: [Int], count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard let position = recency.firstIndex(of: selection) else {
            return wrap(selection, by: delta, count: count)
        }
        return recency[wrap(position, by: delta, count: recency.count)]
    }

    /// Maps a position inside a display group onto an index in the flattened list.
    static func flatIndex(group: Int, item: Int, groupCounts: [Int]) -> Int {
        groupCounts.prefix(group).reduce(item, +)
    }

    /// Drops one window from the snapshot and says where the selection should land.
    ///
    /// The snapshot is deliberately frozen while cycling, so closing a window from a tile is
    /// the one thing that may shorten it. Removing a tile *before* the selection would shift
    /// every later window one place left under the highlight, which is why the selection is
    /// carried by identity rather than left as a raw index. A group emptied by the removal is
    /// dropped as well: a display heading with no tiles under it is not a thing to show.
    static func removing(
        at removed: Int, groupCounts: [Int], selection: Int
    ) -> (groupCounts: [Int], selection: Int) {
        let total = groupCounts.reduce(0, +)
        guard removed >= 0, removed < total else { return (groupCounts, selection) }

        var counts = groupCounts
        var offset = removed
        for (index, count) in counts.enumerated() {
            if offset < count {
                counts[index] -= 1
                break
            }
            offset -= count
        }
        counts.removeAll { $0 == 0 }

        let remaining = total - 1
        guard remaining > 0 else { return (counts, 0) }
        let moved = removed < selection ? selection - 1 : selection
        return (counts, min(moved, remaining - 1))
    }
}
