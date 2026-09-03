import XCTest
@testable import SidekickDock

/// The strip draws one pile per app. These are the rules the pile follows.
final class StripLayoutTests: XCTestCase {

    private func window(_ id: CGWindowID, pid: pid_t, z: Int = 0) -> ManagedWindow {
        ManagedWindow(id: id, pid: pid, bundleIdentifier: nil, appName: "App\(pid)", title: "w",
                      frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                      isActive: false, isMinimized: false, zIndex: z)
    }

    func testAppsKeepTheOrderTheyWereFirstSeenIn() {
        let ordered = StripLayout.ordered(
            [window(3, pid: 20), window(1, pid: 10)],
            appSlot: [10: 0, 20: 1], windowSlot: [1: 5, 3: 2]
        )
        XCTAssertEqual(ordered.map(\.id), [1, 3])
    }

    func testAnAppDoesNotMoveWhenItsWindowIsReplaced() {
        // Terminal keeps more than one window object for one visible window and hands the
        // visible one to a different object each time it is minimised and restored. Deriving
        // the app's place from its windows walked it down the strip on every cycle.
        let before = StripLayout.ordered(
            [window(28029, pid: 5), window(9, pid: 6)],
            appSlot: [5: 0, 6: 1], windowSlot: [28029: 0, 9: 1]
        )
        let after = StripLayout.ordered(
            [window(28039, pid: 5), window(9, pid: 6)],
            appSlot: [5: 0, 6: 1], windowSlot: [28039: 99, 9: 1]
        )
        XCTAssertEqual(before.map(\.pid), after.map(\.pid))
    }

    func testInsideAnAppTheFrontWindowComesFirst() {
        let ordered = StripLayout.ordered(
            [window(1, pid: 7, z: 9), window(2, pid: 7, z: 3)],
            appSlot: [7: 0], windowSlot: [1: 0, 2: 1]
        )
        XCTAssertEqual(ordered.map(\.id), [2, 1])
    }

    func testWindowsOfOneAppStayTogether() {
        let ordered = StripLayout.ordered(
            [window(1, pid: 7, z: 0), window(2, pid: 8, z: 1), window(3, pid: 7, z: 2)],
            appSlot: [7: 0, 8: 1], windowSlot: [1: 0, 2: 1, 3: 2]
        )
        XCTAssertEqual(ordered.map(\.pid), [7, 7, 8])
    }

    func testEachAppBecomesOneStack() {
        let stacks = StripLayout.stacks([
            window(1, pid: 10), window(2, pid: 10), window(3, pid: 20)
        ])
        XCTAssertEqual(stacks.map(\.pid), [10, 20])
        XCTAssertEqual(stacks.map { $0.windows.map(\.id) }, [[1, 2], [3]])
    }

    func testTheOrderItIsGivenIsKept() {
        // WindowStore has already decided where each app sits and where each window sits
        // inside it; re-grouping here would throw that away.
        let stacks = StripLayout.stacks([
            window(3, pid: 20), window(1, pid: 10), window(2, pid: 10)
        ])
        XCTAssertEqual(stacks.map(\.pid), [20, 10])
    }

    func testTheFrontmostWindowIsDrawnLast() {
        // Drawn back to front, so the window on top of the screen is on top of the pile.
        let stack = StripLayout.stacks([window(1, pid: 10, z: 0), window(2, pid: 10, z: 4)])[0]
        XCTAssertEqual(stack.backToFront.map(\.id), [2, 1])
    }

    func testNothingIsLost() {
        let stacks = StripLayout.stacks([window(1, pid: 1), window(2, pid: 2), window(3, pid: 1)])
        XCTAssertEqual(stacks.flatMap { $0.windows.map(\.id) }.sorted(), [1, 2, 3])
    }

    func testAnEmptyStripHasNoStacks() {
        XCTAssertTrue(StripLayout.stacks([]).isEmpty)
    }

    func testHalfOfACardStaysVisible() {
        XCTAssertEqual(StripLayout.overlap(cardHeight: 120), 60)
    }

    func testAShortCardKeepsMoreThanHalf() {
        // Half of a very wide window's short card would be a sliver of nothing.
        XCTAssertEqual(StripLayout.overlap(cardHeight: 40), 14)
        XCTAssertEqual(StripLayout.overlap(cardHeight: 24), 0)
    }
}

extension StripLayoutTests {

    func testTheCardAtTheBackSitsClosestToTheScreenEdge() {
        let front = StripLayout.stagger(behindFront: 0)
        let second = StripLayout.stagger(behindFront: 1)
        let third = StripLayout.stagger(behindFront: 2)
        XCTAssertLessThan(front, second)
        XCTAssertLessThan(second, third)
    }

    func testADeepPileStopsStepping() {
        // The strip is only so wide: past a few windows the ones at the back share the near edge.
        XCTAssertEqual(StripLayout.stagger(behindFront: 3), StripLayout.stagger(behindFront: 40))
    }

    func testALoneWindowIsNotStaggered() {
        // One window is the frontmost of its pile, so it sits where a single card always did.
        XCTAssertEqual(StripLayout.stagger(behindFront: 0), 0)
    }
}
