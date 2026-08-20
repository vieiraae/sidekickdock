import XCTest
@testable import SidekickDock

/// A card must be the shape of the picture it draws. Any disagreement between the two is a
/// preview cropped to a shape it was never captured in.
final class CardGeometryTests: XCTestCase {

    private let width: CGFloat = 184

    func testTheCardTakesTheShapeOfItsPreview() {
        let image = CGSize(width: 2560, height: 1600)
        let aspect = CardGeometry.aspectRatio(image: image, windowAspect: 1.6)
        XCTAssertEqual(CardGeometry.height(width: width, aspectRatio: aspect),
                       width / (2560.0 / 1600.0),
                       accuracy: 0.001)
    }

    func testAResizedWindowDoesNotReshapeTheCardUntilItsPreviewCatchesUp() {
        // The window has just been made tall and narrow; the image on hand is still the wide
        // one. Following the window here is exactly what crops the picture.
        let image = CGSize(width: 1280, height: 800)
        let aspect = CardGeometry.aspectRatio(image: image, windowAspect: 0.5)
        XCTAssertEqual(aspect, 1.6, accuracy: 0.001)
    }

    func testTheWindowShapeIsUsedUntilThereIsAPreview() {
        XCTAssertEqual(CardGeometry.aspectRatio(image: nil, windowAspect: 1.48),
                       1.48,
                       accuracy: 0.001)
    }

    func testADegenerateImageFallsBackToTheWindow() {
        XCTAssertEqual(CardGeometry.aspectRatio(image: .zero, windowAspect: 1.6),
                       1.6,
                       accuracy: 0.001)
        XCTAssertEqual(CardGeometry.aspectRatio(image: CGSize(width: 100, height: 0),
                                                windowAspect: 1.6),
                       1.6,
                       accuracy: 0.001)
    }

    func testAVeryWideWindowStillGetsAReadableCard() {
        XCTAssertEqual(CardGeometry.height(width: width, aspectRatio: 12), CardGeometry.minHeight)
    }

    func testAVeryTallWindowDoesNotRunAwayDownTheStrip() {
        XCTAssertEqual(CardGeometry.height(width: width, aspectRatio: 0.2),
                       width * CardGeometry.maxHeightRatio)
    }

    func testANonsenseAspectDoesNotDivideByZero() {
        XCTAssertEqual(CardGeometry.height(width: width, aspectRatio: 0),
                       width * CardGeometry.maxHeightRatio)
    }

    func testASquareEnoughPictureIsNotCropped() {
        let crop = CardGeometry.cropFraction(image: CGSize(width: 1600, height: 1000), width: 184)
        XCTAssertEqual(crop, 0, accuracy: 0.0001)
    }

    func testATallPictureIsNotCroppedBecauseTheCardNarrows() {
        let crop = CardGeometry.cropFraction(image: CGSize(width: 800, height: 1600), width: 184)
        XCTAssertEqual(crop, 0, accuracy: 0.0001)
    }

    func testATallWindowGetsANarrowerCardOfItsOwnShape() {
        // The 500x867 browser window that was losing 22% of its page.
        let size = CardGeometry.size(width: 184, aspectRatio: 500 / 867)
        XCTAssertEqual(size.height, 184 * CardGeometry.maxHeightRatio, accuracy: 0.01)
        XCTAssertLessThan(size.width, 184)
        XCTAssertEqual(size.width / size.height, 500 / 867, accuracy: 0.001)
    }

    func testAVeryWideWindowKeepsItsShapeInAShortCard() {
        // The 2442x414 browser window that was losing 46% of its sides.
        let crop = CardGeometry.cropFraction(image: CGSize(width: 2442, height: 414), width: 184)
        XCTAssertEqual(crop, 0, accuracy: 0.0001)
        let size = CardGeometry.size(width: 184, aspectRatio: 2442 / 414)
        XCTAssertEqual(size.width, 184, accuracy: 0.01)
        XCTAssertEqual(size.height, 184 / (2442 / 414), accuracy: 0.01)
    }

    func testAnOrdinaryWindowKeepsTheFullStripWidth() {
        let size = CardGeometry.size(width: 184, aspectRatio: 1600 / 1000)
        XCTAssertEqual(size.width, 184, accuracy: 0.01)
        XCTAssertEqual(size.height, 184 / 1.6, accuracy: 0.01)
    }

    func testAVeryWidePictureIsCroppedByTheMinimumHeight() {
        let crop = CardGeometry.cropFraction(image: CGSize(width: 2560, height: 200), width: 184)
        XCTAssertGreaterThan(crop, 0.1)
    }
}
