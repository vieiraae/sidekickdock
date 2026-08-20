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
