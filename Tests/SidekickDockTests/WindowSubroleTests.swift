import XCTest
@testable import SidekickDock

/// Which window-shaped surfaces belong in the strip.
final class WindowSubroleTests: XCTestCase {

    func testAnOrdinaryWindowIsShown() {
        XCTAssertTrue(WindowSubroles.isReal(subrole: kAXStandardWindowSubrole as String))
    }

    func testDialogsAndPanelsAreShown() {
        XCTAssertTrue(WindowSubroles.isReal(subrole: kAXDialogSubrole as String))
        XCTAssertTrue(WindowSubroles.isReal(subrole: kAXSystemDialogSubrole as String))
        XCTAssertTrue(WindowSubroles.isReal(subrole: kAXFloatingWindowSubrole as String))
    }

    func testAnAddressBarSuggestionListIsNot() {
        // Chromium draws it as a full window; Accessibility calls it AXUnknown.
        XCTAssertFalse(WindowSubroles.isReal(subrole: kAXUnknownSubrole as String))
    }

    func testAWindowWithNoAnswerIsShown() {
        // Erring towards an extra card rather than a missing one.
        XCTAssertTrue(WindowSubroles.isReal(subrole: nil))
    }
}

/// How often an app is asked about a window it never describes. Asking costs an Accessibility
/// sweep of the whole app, and one such window used to force one on every tick.
final class SubroleProbeScheduleTests: XCTestCase {

    func testAWindowNeverAskedAboutIsAskedAboutNow() {
        let wanted = WindowSubroles.needsProbing(unjudged: [1, 2], askedAt: [:], now: Date())
        XCTAssertEqual(wanted, [1, 2])
    }

    func testAnUnansweredWindowIsNotAskedAboutAgainImmediately() {
        let now = Date()
        let wanted = WindowSubroles.needsProbing(
            unjudged: [1], askedAt: [1: now.addingTimeInterval(-0.5)], now: now)
        XCTAssertTrue(wanted.isEmpty)
    }

    func testAnUnansweredWindowIsGivenAnotherChanceLater() {
        // An app can simply have been slow to publish a window it will describe eventually.
        let now = Date()
        let wanted = WindowSubroles.needsProbing(
            unjudged: [1], askedAt: [1: now.addingTimeInterval(-6)], now: now)
        XCTAssertEqual(wanted, [1])
    }
}
