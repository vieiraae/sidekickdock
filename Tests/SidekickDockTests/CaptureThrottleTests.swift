import XCTest
@testable import SidekickDock

final class CaptureThrottleTests: XCTestCase {

    func testARevealedStripCapturesEveryTick() {
        var throttle = CaptureThrottle()
        for _ in 0..<10 {
            XCTAssertTrue(throttle.shouldCapture(boosted: true, hasUnattempted: false))
        }
    }

    func testIdleRefreshesAreThrottled() {
        var throttle = CaptureThrottle(every: 4)
        let allowed = (0..<12).filter {
            _ in throttle.shouldCapture(boosted: false, hasUnattempted: false)
        }
        XCTAssertEqual(allowed.count, 3)
    }

    func testAWindowWithNoPreviewYetIsNotMadeToWait() {
        var throttle = CaptureThrottle(every: 4)
        // This is the launch case: the first tick has to capture, or the dock shows grey
        // placeholders for as long as the throttle lasts.
        XCTAssertTrue(throttle.shouldCapture(boosted: false, hasUnattempted: true))
    }

    func testBreakingTheThrottleRestartsItRatherThanSkippingAhead() {
        var throttle = CaptureThrottle(every: 4)
        XCTAssertTrue(throttle.shouldCapture(boosted: false, hasUnattempted: true))
        // The next three ticks are refreshes again, so they wait out a full interval.
        XCTAssertFalse(throttle.shouldCapture(boosted: false, hasUnattempted: false))
        XCTAssertFalse(throttle.shouldCapture(boosted: false, hasUnattempted: false))
        XCTAssertFalse(throttle.shouldCapture(boosted: false, hasUnattempted: false))
        XCTAssertTrue(throttle.shouldCapture(boosted: false, hasUnattempted: false))
    }

    func testAnUncapturableWindowCannotForceEveryTick() {
        // Callers record the *attempt*, not the result, so a window ScreenCaptureKit refuses
        // stops counting as unattempted after one pass and the throttle takes over again.
        var throttle = CaptureThrottle(every: 4)
        XCTAssertTrue(throttle.shouldCapture(boosted: false, hasUnattempted: true))
        let allowed = (0..<8).filter {
            _ in throttle.shouldCapture(boosted: false, hasUnattempted: false)
        }
        XCTAssertEqual(allowed.count, 2)
    }
}
