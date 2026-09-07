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
        let wanted = WindowSubroles.needsProbing(windows: [1, 2], askedAt: [:], now: Date())
        XCTAssertEqual(wanted, [1, 2])
    }

    func testAnUnansweredWindowIsNotAskedAboutAgainImmediately() {
        let now = Date()
        let wanted = WindowSubroles.needsProbing(
            windows: [1], askedAt: [1: now.addingTimeInterval(-0.5)], now: now)
        XCTAssertTrue(wanted.isEmpty)
    }

    func testAnUnansweredWindowIsGivenAnotherChanceLater() {
        // An app can simply have been slow to publish a window it will describe eventually.
        let now = Date()
        let wanted = WindowSubroles.needsProbing(
            windows: [1], askedAt: [1: now.addingTimeInterval(-6)], now: now)
        XCTAssertEqual(wanted, [1])
    }

    func testAWindowKnownToBeRealIsNeverAskedAboutAgain() {
        let now = Date()
        let wanted = WindowSubroles.needsProbing(
            windows: [1],
            verdicts: [1: true],
            askedAt: [1: now.addingTimeInterval(-3600)],
            now: now
        )
        XCTAssertTrue(wanted.isEmpty)
    }

    func testAWindowJustJudgedUnrealIsNotAskedAboutAgainImmediately() {
        // The filter exists to keep a popup surface out of the strip, and re-asking on every
        // tick is the cost this cache was built to avoid.
        let now = Date()
        let wanted = WindowSubroles.needsProbing(
            windows: [1],
            verdicts: [1: false],
            askedAt: [1: now.addingTimeInterval(-5)],
            now: now
        )
        XCTAssertTrue(wanted.isEmpty)
    }

    func testAWindowJudgedUnrealLongAgoIsAskedAboutAgain() {
        // The bug this prevents: a real window that answered AXUnknown while it was still
        // being built stayed hidden for as long as the dock ran — days, in practice.
        let now = Date()
        let wanted = WindowSubroles.needsProbing(
            windows: [1],
            verdicts: [1: false],
            askedAt: [1: now.addingTimeInterval(-31)],
            now: now
        )
        XCTAssertEqual(wanted, [1])
    }

    func testAnUnrealVerdictWithNoTimestampIsAskedAboutAgain() {
        XCTAssertEqual(
            WindowSubroles.needsProbing(windows: [1], verdicts: [1: false], askedAt: [:]), [1]
        )
    }
}
