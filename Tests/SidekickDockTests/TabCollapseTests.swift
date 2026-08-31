import XCTest
@testable import SidekickDock

/// A tabbed window that has been minimised. Measured on Terminal: each tab has its own
/// CoreGraphics window, and minimising makes the app report all of them as minimised windows
/// at the same frame — so the strip grew a card per tab for one minimised window.
final class TabCollapseTests: XCTestCase {

    private let frame = CGRect(x: 234, y: 206, width: 877, height: 535)

    private func window(
        _ id: CGWindowID, pid: pid_t = 1, frame: CGRect, minimized: Bool = true
    ) -> ManagedWindow {
        ManagedWindow(id: id, pid: pid, bundleIdentifier: nil, appName: "Terminal", title: "zsh",
                      frame: frame, isActive: false, isMinimized: minimized)
    }

    func testTabsOfOneWindowBecomeOneCard() {
        let kept = WindowEnumerator.collapsingTabs([
            window(31348, frame: frame), window(28455, frame: frame), window(28039, frame: frame)
        ])
        XCTAssertEqual(kept.map(\.id), [31348])
    }

    func testTheCardTheUserIsAlreadyLookingAtKeepsItsIdentity() {
        // Handing the card to a different tab at the moment of minimising is what made the
        // graces hold the abandoned ID as a second card.
        let kept = WindowEnumerator.collapsingTabs(
            [window(31348, frame: frame), window(28455, frame: frame)],
            preferring: [28455]
        )
        XCTAssertEqual(kept.map(\.id), [28455])
    }

    func testAGraceCardIsDroppedRatherThanShownBesideItsOwnWindow() {
        // The reported bug: a minimised card and an "active" one for the same window, the
        // second being a card held through the animation under the abandoned tab's ID.
        let onScreen = window(28455, frame: frame, minimized: false)
        let ghost = window(31348, frame: frame, minimized: false)
        let kept = WindowEnumerator.collapsingTabs([onScreen, ghost], onScreen: [28455])
        XCTAssertEqual(kept.map(\.id), [28455])
    }

    func testAnOnScreenWindowIsNeverRemoved() {
        let a = window(1, frame: frame, minimized: false)
        let b = window(2, frame: frame, minimized: false)
        let kept = WindowEnumerator.collapsingTabs([a, b], onScreen: [1, 2])
        XCTAssertEqual(kept.map(\.id), [1, 2])
    }

    func testTwoRealWindowsAreBothKept() {
        let kept = WindowEnumerator.collapsingTabs([
            window(1, frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            window(2, frame: CGRect(x: 40, y: 40, width: 800, height: 600))
        ])
        XCTAssertEqual(kept.map(\.id), [1, 2])
    }

    func testWindowsOfDifferentAppsAreNeverCollapsed() {
        let kept = WindowEnumerator.collapsingTabs([
            window(1, pid: 1, frame: frame), window(2, pid: 2, frame: frame)
        ])
        XCTAssertEqual(kept.map(\.id), [1, 2])
    }

    func testTheTabThatWasOnScreenWinsOverZOrder() {
        // The tab the user was working in is the one that must be restored: focusing a tab's
        // window is what selects that tab, so keeping the window server's first listing
        // brought the window back with the wrong tab in front.
        let kept = WindowEnumerator.collapsingTabs(
            [window(28039, frame: frame), window(28029, frame: frame), window(31636, frame: frame)],
            preferring: [28029]
        )
        XCTAssertEqual(kept.map(\.id), [28029])
    }

    func testAnAnchorForAnotherWindowDoesNotDecideThisOne() {
        let other = CGRect(x: 10, y: 10, width: 400, height: 300)
        let kept = WindowEnumerator.collapsingTabs(
            [window(28039, frame: frame), window(28029, frame: frame),
             window(7, pid: 2, frame: other)],
            preferring: [7]
        )
        XCTAssertEqual(kept.map(\.id).sorted(), [7, 28039])
    }
}
