import XCTest
@testable import SidekickDock

/// Picking the one real window out of the surfaces that share a full-screen Space.
///
/// The fixtures are the real contents of two full-screen Spaces, read from the window server
/// while TextEdit and Teams were full screen on a Space the user had swiped away from.
final class FullScreenSpaceTests: XCTestCase {

    private func entry(
        id: CGWindowID, owner: String, title: String, width: CGFloat, height: CGFloat,
        layer: Int = 0, alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowOwnerName as String: owner,
            kCGWindowName as String: title,
            kCGWindowBounds as String: [
                "X": 0, "Y": 0, "Width": width, "Height": height
            ] as [String: Any]
        ]
    }

    private var textEditSpace: [[String: Any]] {
        [
            entry(id: 21039, owner: "Dock", title: "Wallpaper-78D0", width: 1312, height: 848,
                  layer: -2147483624),
            entry(id: 21040, owner: "Dock", title: "Fullscreen Backdrop", width: 1312, height: 848,
                  layer: -2147483622),
            entry(id: 21056, owner: "Window Server", title: "Menubar", width: 1312, height: 26,
                  layer: 24),
            entry(id: 21038, owner: "TextEdit", title: "", width: 1312, height: 104),
            entry(id: 21035, owner: "TextEdit", title: "Untitled 2", width: 1312, height: 786)
        ]
    }

    func testPicksTheWindowRatherThanTheAppsFullScreenToolbar() {
        // The toolbar is layer 0, fully opaque and app-owned exactly as the window is, so
        // nothing but the title and the size tells them apart. It was showing up as a second,
        // sliver-shaped card for the same app.
        let picked = WindowEnumerator.fullScreenWindow(among: textEditSpace)
        XCTAssertEqual(
            (picked?[kCGWindowNumber as String] as? NSNumber)?.uint32Value, 21035
        )
    }

    func testIgnoresUntitledSurfaces() {
        let onlyChrome = textEditSpace.filter {
            ($0[kCGWindowName as String] as? String)?.isEmpty == true
        }
        XCTAssertNil(WindowEnumerator.fullScreenWindow(among: onlyChrome))
    }

    func testRejectsTheWallpaperAndBackdropDespiteTheirTitlesAndSize() {
        // Both are larger than the window and both carry titles, so only their layer keeps
        // them out. Picking one of them would yield no card at all: the Dock is not an app a
        // user switches to, so the choice is thrown away rather than corrected.
        let decorations = textEditSpace.filter {
            ($0[kCGWindowOwnerName as String] as? String) != "TextEdit"
        }
        XCTAssertNil(WindowEnumerator.fullScreenWindow(among: decorations))
    }

    func testPicksTheWindowAmongTheAppsOwnSurfaces() {
        let teams = [
            entry(id: 20255, owner: "Microsoft Teams", title: "", width: 1312, height: 32, alpha: 0),
            entry(id: 19921, owner: "Microsoft Teams", title: "Coffee Chat", width: 1312, height: 822)
        ]
        let picked = WindowEnumerator.fullScreenWindow(among: teams)
        XCTAssertEqual(
            (picked?[kCGWindowNumber as String] as? NSNumber)?.uint32Value, 19921
        )
    }

    func testEmptySpaceYieldsNothing() {
        XCTAssertNil(WindowEnumerator.fullScreenWindow(among: []))
    }
}
