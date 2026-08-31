import XCTest
@testable import SidekickDock

/// A tabbed window that has been minimised. Measured on Terminal: each tab has its own
/// CoreGraphics window, and minimising makes the app report all of them as minimised windows
/// at the same frame — so the strip grew a card per tab for one minimised window.
final class TabCollapseTests: XCTestCase {

    private func window(_ id: CGWindowID, pid: pid_t = 1, frame: CGRect) -> ManagedWindow {
        ManagedWindow(id: id, pid: pid, bundleIdentifier: nil, appName: "Terminal", title: "zsh",
                      frame: frame, isActive: false, isMinimized: true)
    }

    func testTabsOfOneWindowBecomeOneCard() {
        let frame = CGRect(x: 234, y: 206, width: 877, height: 535)
        let kept = WindowEnumerator.collapsingTabs([
            window(31348, frame: frame), window(28455, frame: frame), window(28039, frame: frame)
        ])
        // The frontmost is kept: it is the tab the app brings back.
        XCTAssertEqual(kept.map(\.id), [31348])
    }

    func testTwoRealWindowsAreBothKept() {
        let kept = WindowEnumerator.collapsingTabs([
            window(1, frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            window(2, frame: CGRect(x: 40, y: 40, width: 800, height: 600))
        ])
        XCTAssertEqual(kept.map(\.id), [1, 2])
    }

    func testWindowsOfDifferentAppsAreNeverCollapsed() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let kept = WindowEnumerator.collapsingTabs([
            window(1, pid: 1, frame: frame), window(2, pid: 2, frame: frame)
        ])
        XCTAssertEqual(kept.map(\.id), [1, 2])
    }
}
