import XCTest
@testable import SidekickDock

/// Flipping between AppKit's bottom-left origin and CoreGraphics' top-left origin, and
/// deciding which display a window belongs to.
///
/// Cross-display placement broke repeatedly on exactly this arithmetic, and it is only
/// visibly wrong on a second monitor — so it is worth pinning down without one.
final class ScreenGeometryTests: XCTestCase {

    private let globalHeight: CGFloat = 982  // built-in display, AppKit height

    func testPrimaryDisplayIsUnchangedByTheFlip() {
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(ScreenGeometry.flip(primary, globalHeight: globalHeight), primary)
    }

    func testFlipIsItsOwnInverse() {
        let rect = CGRect(x: 120, y: 40, width: 800, height: 600)
        let there = ScreenGeometry.flip(rect, globalHeight: globalHeight)
        XCTAssertEqual(ScreenGeometry.flip(there, globalHeight: globalHeight), rect)
    }

    /// A display sitting *above* the primary one has a positive AppKit origin and a negative
    /// CoreGraphics origin. Getting this backwards is what sent windows to the wrong strip.
    func testDisplayAboveThePrimaryFlipsToANegativeOrigin() {
        let above = CGRect(x: 0, y: 982, width: 2560, height: 1080)
        let flipped = ScreenGeometry.flip(above, globalHeight: globalHeight)

        XCTAssertEqual(flipped.origin.y, -1080)
        XCTAssertEqual(flipped.maxY, 0, "its bottom edge meets the top of the primary display")
        XCTAssertEqual(flipped.size, above.size)
    }

    func testFlipKeepsHorizontalPositionAndSize() {
        let right = CGRect(x: 1512, y: -98, width: 2560, height: 1080)
        let flipped = ScreenGeometry.flip(right, globalHeight: globalHeight)

        XCTAssertEqual(flipped.origin.x, 1512)
        XCTAssertEqual(flipped.size, right.size)
    }

    // MARK: - Display ownership

    /// Primary display plus an external one to its right, both in CoreGraphics space.
    private let displays: [(id: CGDirectDisplayID, frame: CGRect)] = [
        (1, CGRect(x: 0, y: 0, width: 1512, height: 982)),
        (2, CGRect(x: 1512, y: 0, width: 2560, height: 1080))
    ]

    func testWindowFullyOnADisplayBelongsToIt() {
        let window = CGRect(x: 1600, y: 100, width: 800, height: 600)
        XCTAssertEqual(ScreenGeometry.owningDisplay(for: window, among: displays), 2)
    }

    func testStraddlingWindowGoesToTheDisplayHoldingMoreOfIt() {
        // 200pt on the primary, 600pt on the external.
        let window = CGRect(x: 1312, y: 100, width: 800, height: 600)
        XCTAssertEqual(ScreenGeometry.owningDisplay(for: window, among: displays), 2)

        // The mirror image, mostly on the primary.
        let other = CGRect(x: 912, y: 100, width: 800, height: 600)
        XCTAssertEqual(ScreenGeometry.owningDisplay(for: other, among: displays), 1)
    }

    func testOffScreenWindowFallsBackToTheNearestDisplay() {
        let farRight = CGRect(x: 5000, y: 200, width: 400, height: 300)
        XCTAssertEqual(ScreenGeometry.owningDisplay(for: farRight, among: displays), 2)

        let farLeft = CGRect(x: -900, y: 200, width: 400, height: 300)
        XCTAssertEqual(ScreenGeometry.owningDisplay(for: farLeft, among: displays), 1)
    }

    func testZeroSizedWindowStillResolvesToADisplay() {
        // No overlap area at all, so this takes the nearest-display path. It must land on the
        // display the window actually sits inside, not the one whose centre is closest — the
        // primary display's centre is nearer, and that used to win.
        let empty = CGRect(x: 1600, y: 300, width: 0, height: 0)
        XCTAssertEqual(ScreenGeometry.owningDisplay(for: empty, among: displays), 2)
    }

    func testNoDisplaysYieldsNoOwner() {
        XCTAssertNil(ScreenGeometry.owningDisplay(for: .zero, among: []))
    }
}
