import XCTest
@testable import SidekickDock

/// Which windows a capture pass photographs. A pass is measured at ~50ms per window, so this
/// choice is the difference between a burst of work and continuous work while a strip is open.
final class CaptureTargetTests: XCTestCase {

    private func window(_ id: CGWindowID) -> ManagedWindow {
        ManagedWindow(id: id, pid: 1, bundleIdentifier: nil, appName: "App", title: "",
                      frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                      isActive: false, isMinimized: false)
    }

    func testNothingRevealedRefreshesEverything() {
        let windows = [window(1), window(2)]
        let targets = WindowStore.captureTargets(
            windows: windows, displays: [1: 10, 2: 20], revealed: [], attempted: [1, 2])
        XCTAssertEqual(targets.map(\.id), [1, 2])
    }

    func testOnlyTheOpenDisplayIsRefreshed() {
        let windows = [window(1), window(2)]
        let targets = WindowStore.captureTargets(
            windows: windows, displays: [1: 10, 2: 20], revealed: [10], attempted: [1, 2])
        XCTAssertEqual(targets.map(\.id), [1])
    }

    func testAWindowWithNoPreviewYetIsAlwaysIncluded() {
        // Otherwise a card on the other display keeps its app icon until the strip is opened
        // there — including every card at launch.
        let windows = [window(1), window(2)]
        let targets = WindowStore.captureTargets(
            windows: windows, displays: [1: 10, 2: 20], revealed: [10], attempted: [1])
        XCTAssertEqual(targets.map(\.id), [1, 2])
    }

    func testAWindowOnNoKnownDisplayIsIncluded() {
        let targets = WindowStore.captureTargets(
            windows: [window(3)], displays: [:], revealed: [10], attempted: [3])
        XCTAssertEqual(targets.map(\.id), [3])
    }
}
