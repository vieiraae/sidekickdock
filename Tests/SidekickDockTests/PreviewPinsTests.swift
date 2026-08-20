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
