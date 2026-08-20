import XCTest
@testable import SidekickDock

/// Most-recently-used ordering, which is what ⌘Tab traverses.
///
/// The window server's stacking order used to stand in for this, and it was wrong: the dock
/// raises windows without focusing them, which moves them to the front of the stack without
/// them ever having been used.
@MainActor
final class UsageHistoryTests: XCTestCase {

    /// The history is a process-wide singleton with a monotonic counter, so each test works on
    /// its own window IDs rather than trying to reset shared state.
    private let history = UsageHistory.shared

    func testUnseenWindowsKeepTheirIncomingOrder() {
        let ids: [CGWindowID] = [1001, 1002, 1003]
        XCTAssertEqual(history.ordered(ids), ids)
    }

    func testMostRecentlyRecordedComesFirst() {
        history.record(2001)
        history.record(2002)
        history.record(2003)

        XCTAssertEqual(history.ordered([2001, 2002, 2003]), [2003, 2002, 2001])
    }

    func testReRecordingMovesAWindowToTheFront() {
        history.record(3001)
        history.record(3002)
        history.record(3001)

        XCTAssertEqual(history.ordered([3001, 3002]), [3001, 3002])
    }

    func testSeenWindowsSortAheadOfUnseenOnes() {
        history.record(4002)

        // 4001 and 4003 have never held focus, so they fall to the back in their given order.
        XCTAssertEqual(history.ordered([4001, 4002, 4003]), [4002, 4001, 4003])
    }

    func testOrderingDoesNotDropOrDuplicateWindows() {
        history.record(5003)
        history.record(5001)
        let ids: [CGWindowID] = [5001, 5002, 5003, 5004]

        XCTAssertEqual(Set(history.ordered(ids)), Set(ids))
        XCTAssertEqual(history.ordered(ids).count, ids.count)
    }

    func testPruningForgetsWindowsThatAreGone() {
        history.record(6001)
        history.record(6002)
        history.prune(keeping: [6002])

        // 6001 is unseen again, so it drops behind the window that is still known.
        XCTAssertEqual(history.ordered([6001, 6002]), [6002, 6001])
    }

    func testPruningKeepsTheOrderOfSurvivors() {
        history.record(7001)
        history.record(7002)
        history.prune(keeping: [7001, 7002])

        XCTAssertEqual(history.ordered([7001, 7002]), [7002, 7001])
    }
}
