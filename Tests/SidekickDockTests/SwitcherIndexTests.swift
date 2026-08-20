import XCTest
@testable import SidekickDock

/// The switcher's index arithmetic: wrap-around, most-recently-used traversal, and the map
/// from a grid position to the flattened selection.
final class SwitcherIndexTests: XCTestCase {

    func testStepsForwardAndBackwards() {
        XCTAssertEqual(SwitcherIndex.wrap(0, by: 1, count: 4), 1)
        XCTAssertEqual(SwitcherIndex.wrap(2, by: -1, count: 4), 1)
    }

    func testWrapsPastBothEnds() {
        XCTAssertEqual(SwitcherIndex.wrap(3, by: 1, count: 4), 0, "off the end wraps to the front")
        XCTAssertEqual(SwitcherIndex.wrap(0, by: -1, count: 4), 3, "off the front wraps to the end")
    }

    func testWrapsRepeatedly() {
        XCTAssertEqual(SwitcherIndex.wrap(0, by: 9, count: 4), 1)
        XCTAssertEqual(SwitcherIndex.wrap(0, by: -9, count: 4), 3)
    }

    func testSingleWindowStaysPut() {
        XCTAssertEqual(SwitcherIndex.wrap(0, by: 1, count: 1), 0)
        XCTAssertEqual(SwitcherIndex.wrap(0, by: -1, count: 1), 0)
    }

    func testEmptyListDoesNotTrap() {
        XCTAssertEqual(SwitcherIndex.wrap(0, by: 1, count: 0), 0)
        XCTAssertEqual(SwitcherIndex.stepInRecency(selection: 0, by: 1, recency: [], count: 0), 0)
    }

    // MARK: - Recency traversal

    /// Windows drawn in spatial order 0,1,2,3 but last used in the order 2,0,3,1.
    private let recency = [2, 0, 3, 1]

    func testTabWalksTheRecencyOrderNotTheGrid() {
        // Starting on the most recent window, one press lands on the one used before it.
        XCTAssertEqual(SwitcherIndex.stepInRecency(selection: 2, by: 1, recency: recency, count: 4), 0)
        XCTAssertEqual(SwitcherIndex.stepInRecency(selection: 0, by: 1, recency: recency, count: 4), 3)
    }

    func testShiftTabWalksBackAndWraps() {
        XCTAssertEqual(SwitcherIndex.stepInRecency(selection: 0, by: -1, recency: recency, count: 4), 2)
        XCTAssertEqual(SwitcherIndex.stepInRecency(selection: 2, by: -1, recency: recency, count: 4), 1,
                       "stepping back from the newest wraps to the oldest")
    }

    func testFullCycleReturnsToTheStart() {
        var selection = recency[0]
        for _ in 0..<recency.count {
            selection = SwitcherIndex.stepInRecency(selection: selection, by: 1,
                                                    recency: recency, count: 4)
        }
        XCTAssertEqual(selection, recency[0])
    }

    func testSelectionOutsideTheRecencyListFallsBackToSpatialOrder() {
        // Should not happen, but it must move rather than stick.
        XCTAssertEqual(SwitcherIndex.stepInRecency(selection: 1, by: 1, recency: [0, 2], count: 4), 2)
    }

    // MARK: - Flattening

    func testFlatIndexOffsetsByThePrecedingDisplays() {
        let counts = [3, 2, 4]  // three displays

        XCTAssertEqual(SwitcherIndex.flatIndex(group: 0, item: 0, groupCounts: counts), 0)
        XCTAssertEqual(SwitcherIndex.flatIndex(group: 0, item: 2, groupCounts: counts), 2)
        XCTAssertEqual(SwitcherIndex.flatIndex(group: 1, item: 0, groupCounts: counts), 3)
        XCTAssertEqual(SwitcherIndex.flatIndex(group: 2, item: 3, groupCounts: counts), 8)
    }

    func testFlatIndexCoversEveryPositionExactlyOnce() {
        let counts = [3, 2, 4]
        let flattened = counts.enumerated().flatMap { group, count in
            (0..<count).map { SwitcherIndex.flatIndex(group: group, item: $0, groupCounts: counts) }
        }
        XCTAssertEqual(flattened, Array(0..<counts.reduce(0, +)))
    }

    func testEmptyDisplayDoesNotShiftTheOnesAfterIt() {
        let counts = [2, 0, 3]
        XCTAssertEqual(SwitcherIndex.flatIndex(group: 2, item: 0, groupCounts: counts), 2)
    }
}
