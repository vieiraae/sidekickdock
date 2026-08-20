import XCTest
@testable import SidekickDock

/// The tiling geometry: unit panes scaled onto a display's usable area.
///
/// Both spaces have a top-left origin, and the area is the *visible* frame, so a tile must
/// never reach under the menu bar or the Dock.
final class WindowTilerTests: XCTestCase {

    /// A 1512x945 display with a 25pt menu bar, positioned to the right of the primary one so
    /// a non-zero origin is always in play — origin handling is where this last went wrong.
    private let area = CGRect(x: 1512, y: 25, width: 1512, height: 920)

    func testFillCoversTheWholeVisibleArea() {
        XCTAssertEqual(WindowTiler.frame(for: WindowTiler.Tile.fill.unitRect, in: area), area)
    }

    func testHalvesSplitTheAreaWithoutGapOrOverlap() {
        let left = WindowTiler.frame(for: WindowTiler.Tile.left.unitRect, in: area)
        let right = WindowTiler.frame(for: WindowTiler.Tile.right.unitRect, in: area)

        XCTAssertEqual(left, CGRect(x: 1512, y: 25, width: 756, height: 920))
        XCTAssertEqual(right, CGRect(x: 2268, y: 25, width: 756, height: 920))
        XCTAssertEqual(left.maxX, right.minX, "halves must meet exactly")
        XCTAssertEqual(left.union(right), area)
    }

    func testTopAndBottomSplitVertically() {
        let top = WindowTiler.frame(for: WindowTiler.Tile.top.unitRect, in: area)
        let bottom = WindowTiler.frame(for: WindowTiler.Tile.bottom.unitRect, in: area)

        XCTAssertEqual(top.minY, area.minY, "top edge is the top of the visible area, not the screen")
        XCTAssertEqual(top.maxY, bottom.minY)
        XCTAssertEqual(bottom.maxY, area.maxY)
    }

    func testCornerTilesAreQuarters() {
        let corners: [WindowTiler.Tile] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let rects = corners.map { WindowTiler.frame(for: $0.unitRect, in: area) }

        for rect in rects {
            XCTAssertEqual(rect.width, area.width / 2)
            XCTAssertEqual(rect.height, area.height / 2)
        }
        XCTAssertEqual(rects.reduce(CGRect.null) { $0.union($1) }, area)
        assertDisjoint(rects)
    }

    func testEveryTileStaysInsideTheVisibleArea() {
        for tile in WindowTiler.Tile.allCases {
            let rect = WindowTiler.frame(for: tile.unitRect, in: area)
            XCTAssertTrue(area.contains(rect), "\(tile.rawValue) escapes the visible area: \(rect)")
        }
    }

    // MARK: - Arrangements

    func testArrangementPanesTileTheAreaExactly() {
        for arrangement in WindowTiler.Arrangement.allCases {
            let rects = arrangement.panes.map { WindowTiler.frame(for: $0, in: area) }
            let covered = rects.reduce(0) { $0 + $1.width * $1.height }

            XCTAssertEqual(rects.reduce(CGRect.null) { $0.union($1) }, area,
                           "\(arrangement.rawValue) leaves part of the display uncovered")
            XCTAssertEqual(covered, area.width * area.height, accuracy: 0.001,
                           "\(arrangement.rawValue) panes overlap or leave a gap")
            assertDisjoint(rects, label: arrangement.rawValue)
        }
    }

    func testLeftAndQuartersPutsTheChosenWindowInTheFullHeightPane() {
        let panes = WindowTiler.Arrangement.leftAndQuarters.panes.map {
            WindowTiler.frame(for: $0, in: area)
        }

        // The first pane belongs to the window the menu was opened for.
        XCTAssertEqual(panes[0], CGRect(x: 1512, y: 25, width: 756, height: 920))
        XCTAssertEqual(panes[1].height, area.height / 2)
        XCTAssertEqual(panes[2].height, area.height / 2)
        XCTAssertEqual(panes[1].maxY, panes[2].minY, "the quarters must meet")
    }

    func testPaneCountsMatchTheirLabels() {
        XCTAssertEqual(WindowTiler.Arrangement.fill.panes.count, 1)
        XCTAssertEqual(WindowTiler.Arrangement.leftAndRight.panes.count, 2)
        XCTAssertEqual(WindowTiler.Arrangement.leftAndQuarters.panes.count, 3)
        XCTAssertEqual(WindowTiler.Arrangement.quarters.panes.count, 4)
    }

    private func assertDisjoint(_ rects: [CGRect], label: String = "", file: StaticString = #filePath,
                                line: UInt = #line) {
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                let overlap = a.intersection(b)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                XCTAssertEqual(area, 0, "\(label) panes overlap: \(a) and \(b)", file: file, line: line)
            }
        }
    }
}
