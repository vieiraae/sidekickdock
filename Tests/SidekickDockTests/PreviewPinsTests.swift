import XCTest
@testable import SidekickDock

/// Freezing a preview across the minimise and restore animations.
final class PreviewPinsTests: XCTestCase {

    /// A pin taken long enough ago that the grace no longer applies.
    private let old = Date(timeIntervalSinceNow: -PreviewPins.grace - 1)
    private let now = Date()

    /// The reason the first attempt at this failed: a tick lands between the click and
    /// Accessibility reporting the window as minimised, and at that instant the window is
    /// neither minimised nor moving. Without the grace the pin is dropped right there and the
    /// genie is captured anyway.
    func testPinSurvivesTheInstantAfterTheClick() {
        let pins = PreviewPins.retained([1: now], presentMinimised: [1: false], unsettled: [],
                                        now: now)
        XCTAssertEqual(Set(pins.keys), [1])
    }

    func testPinSurvivesWhileTheWindowIsMinimised() {
        let pins = PreviewPins.retained([1: old], presentMinimised: [1: true], unsettled: [])
        XCTAssertEqual(Set(pins.keys), [1])
    }

    /// Mid-animation a window can drop out of the list for a tick, which must not release it.
    func testPinSurvivesAWindowMissingForAMoment() {
        let pins = PreviewPins.retained([1: now], presentMinimised: [:], unsettled: [], now: now)
        XCTAssertEqual(Set(pins.keys), [1])
    }

    func testPinIsReleasedOnceTheWindowIsBackAndStill() {
        let pins = PreviewPins.retained([1: old], presentMinimised: [1: false], unsettled: [])
        XCTAssertTrue(pins.isEmpty)
    }

    /// The restore is an animation too, so letting go the moment the window stops being
    /// minimised would hand it the same opening the minimise had.
    func testPinSurvivesTheRestoreAnimation() {
        let pins = PreviewPins.retained([1: old], presentMinimised: [1: false], unsettled: [1])
        XCTAssertEqual(Set(pins.keys), [1])
    }

    func testPinIsDroppedWhenTheWindowIsGone() {
        let pins = PreviewPins.retained([1: old], presentMinimised: [2: true], unsettled: [])
        XCTAssertTrue(pins.isEmpty)
    }

    func testPinsAreIndependent() {
        let pins = PreviewPins.retained(
            [1: old, 2: old, 3: old],
            presentMinimised: [1: true, 2: false, 3: false],
            unsettled: [3]
        )
        XCTAssertEqual(Set(pins.keys), [1, 3])
    }

    func testNoPinsStaysEmpty() {
        XCTAssertTrue(PreviewPins.retained([:], presentMinimised: [1: true], unsettled: [1]).isEmpty)
    }
}

/// Rejecting captures that are the wrong shape for their window, which is what a frame of a
/// resize or full-screen transition looks like.
final class PreviewShapeTests: XCTestCase {

    private let window = CGSize(width: 1200, height: 800)

    func testAMatchingCaptureIsAccepted() {
        // 2x capture of the same window.
        XCTAssertTrue(PreviewPins.shapeMatches(image: CGSize(width: 2400, height: 1600),
                                               window: window))
    }

    func testRoundingIsTolerated() {
        // Capture sizes are rounded to whole pixels, so they never match exactly.
        XCTAssertTrue(PreviewPins.shapeMatches(image: CGSize(width: 601, height: 399),
                                               window: window))
    }

    func testASmearedCaptureIsRejected() {
        // Mid-genie the window is drawn far taller than it is wide.
        XCTAssertFalse(PreviewPins.shapeMatches(image: CGSize(width: 600, height: 900),
                                                window: window))
    }

    func testACaptureFromBeforeAResizeIsRejected() {
        // The window has just been tiled to a half; the image is still the old full-screen one.
        XCTAssertFalse(PreviewPins.shapeMatches(image: CGSize(width: 1200, height: 400),
                                                window: CGSize(width: 600, height: 800)))
    }

    func testDegenerateSizesAreRejected() {
        XCTAssertFalse(PreviewPins.shapeMatches(image: .zero, window: window))
        XCTAssertFalse(PreviewPins.shapeMatches(image: CGSize(width: 100, height: 100),
                                                window: .zero))
    }
}
