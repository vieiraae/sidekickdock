import CoreGraphics

/// Which parts of a dock panel are solid.
///
/// A panel is a rectangle running most of the height of its display, but the cards inside it
/// are islands with desktop showing between and around them. Treating the whole rectangle as
/// solid means it swallows clicks meant for what is behind it — the close button of a window
/// that reaches the screen edge, or the desktop in the gap between two cards.
enum PanelHitTesting {

    /// Sideways slack around a card, in points.
    ///
    /// A card's measured frame knows nothing about what is drawn on top of it: the strip's
    /// perspective tilt shears cards sideways, and a hovered card lifts and slides. Erring
    /// outwards costs a few points of desktop beside each card; erring inwards would drop
    /// clicks meant for a card, which is far worse.
    static let horizontalMargin: CGFloat = 10
    /// Vertical slack. Deliberately smaller than the sideways margin: the gap between cards is
    /// only `Theme.cardSpacing` tall, and it is exactly the gap the user wants to click through.
    static let verticalMargin: CGFloat = 3

    /// Converts card rectangles measured inside the panel — y running down from its top
    /// left — into screen rectangles, which run up from the bottom left.
    static func solidRects(cards: [CGRect], panel: CGRect) -> [CGRect] {
        cards.map { card in
            CGRect(x: panel.minX + card.minX - horizontalMargin,
                   y: panel.maxY - card.maxY - verticalMargin,
                   width: card.width + horizontalMargin * 2,
                   height: card.height + verticalMargin * 2)
        }
    }

    static func isSolid(point: CGPoint, cards: [CGRect], panel: CGRect) -> Bool {
        solidRects(cards: cards, panel: panel).contains { $0.contains(point) }
    }
}
