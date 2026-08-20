import XCTest
@testable import SidekickDock

final class PanelHitTestingTests: XCTestCase {

    /// A panel on the left of a 1000pt-tall display, with one 100x60 card near its top.
    private let panel = CGRect(x: 0, y: 0, width: 266, height: 1000)
    private let card = CGRect(x: 14, y: 100, width: 100, height: 60)

    func testACardIsSolidWhereItIsDrawn() {
        // The card's centre sits 130pt down the panel, so 870pt up from the bottom.
        XCTAssertTrue(PanelHitTesting.isSolid(point: CGPoint(x: 64, y: 870), cards: [card], panel: panel))
    }

    func testThePanelPassesClicksThroughAboveAndBelowTheCards() {
        XCTAssertFalse(PanelHitTesting.isSolid(point: CGPoint(x: 64, y: 990), cards: [card], panel: panel))
        XCTAssertFalse(PanelHitTesting.isSolid(point: CGPoint(x: 64, y: 200), cards: [card], panel: panel))
    }

    func testTheGapBetweenTwoCardsStaysClickable() {
        let second = CGRect(x: 14, y: 176, width: 100, height: 60)  // 16pt below the first
        let middleOfGap = CGPoint(x: 64, y: panel.maxY - 168)
        XCTAssertFalse(PanelHitTesting.isSolid(point: middleOfGap, cards: [card, second], panel: panel))
    }

    func testAnEmptyPanelIsEntirelyClickThrough() {
        XCTAssertFalse(PanelHitTesting.isSolid(point: CGPoint(x: 64, y: 500), cards: [], panel: panel))
    }

    func testTheMarginKeepsClicksJustOutsideACardOnTheCard() {
        let justLeft = CGPoint(x: panel.minX + card.minX - 5, y: 870)
        XCTAssertTrue(PanelHitTesting.isSolid(point: justLeft, cards: [card], panel: panel))
    }

    func testRectsFollowThePanelAroundTheScreen() {
        let moved = CGRect(x: -657, y: 848, width: 266, height: 1000)
        let rects = PanelHitTesting.solidRects(cards: [card], panel: moved)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, moved.minX + card.minX - PanelHitTesting.horizontalMargin)
        XCTAssertEqual(rects[0].maxY, moved.maxY - card.minY + PanelHitTesting.verticalMargin)
    }
}
