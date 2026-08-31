import CoreGraphics
import Foundation

/// Remembers when each window last held focus, so the switcher can cycle in
/// most-recently-used order.
///
/// The strips deliberately stay in spatial order — cards that reshuffle under
/// the pointer are hard to aim at — so this exists only to drive ⌘Tab
/// traversal, where "flip back to the window I was just in" is the whole point.
///
/// Previously the switcher approximated recency with the window server's
/// stacking order. That is only a proxy: raising a window without focusing it
/// (which this app does routinely) moves it to the front of the stack without
/// it ever having been used.
@MainActor
final class UsageHistory {
    static let shared = UsageHistory()

    /// Rises on every record. A monotonic counter rather than a timestamp, so
    /// ordering cannot be disturbed by clock resolution or by the clock moving
    /// backwards.
    private var counter: UInt64 = 0
    private var sequence: [CGWindowID: UInt64] = [:]

    private init() {}

    func record(_ id: CGWindowID) {
        // Already the newest: the focused window is re-recorded on every tick, and
        // bumping the counter each time would churn for no change in order.
        if sequence[id] == counter, counter != 0 { return }
        counter &+= 1
        sequence[id] = counter
    }

    /// Drops windows that no longer exist, so the table cannot grow without bound
    /// across a long session.
    func prune(keeping ids: Set<CGWindowID>) {
        // Compared as sets rather than by count: two tables of the same size can still hold
        // different windows, and a count test would keep the stale ones for ever.
        guard !sequence.keys.allSatisfy(ids.contains) else { return }
        sequence = sequence.filter { ids.contains($0.key) }
    }

    /// The given windows reordered newest-first.
    ///
    /// Windows never seen in focus keep their incoming relative order and sit at
    /// the back, so a fresh launch degrades to the spatial order rather than to
    /// something arbitrary.
    func ordered(_ ids: [CGWindowID]) -> [CGWindowID] {
        ids.enumerated().sorted { lhs, rhs in
            switch (sequence[lhs.element], sequence[rhs.element]) {
            case let (l?, r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
