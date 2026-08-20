import CoreGraphics

/// How tall a card is for a given preview.
enum CardGeometry {

    /// A card is never thinner than this, however wide its window is.
    ///
    /// Low, because a card that refuses to be short has to cut the sides off a very wide
    /// window — a 2442x414 browser window lost 46% of itself to a 58pt floor. At 24pt a
    /// window up to about 7.7:1 still fits whole, and anything wider than that is a sliver
    /// no preview could say much about anyway.
    static let minHeight: CGFloat = 24
    /// Nor taller than this multiple of its width, however tall its window is.
    static let maxHeightRatio: CGFloat = 1.35

    /// The shape the card takes: the shape of the picture it is about to draw, falling back to
    /// the window's own shape when there is no picture yet.
    ///
    /// Previews arrive on their own cadence — as slowly as every few seconds while nothing is
    /// revealed — so between a window being resized and its next capture landing, the live
    /// frame and the image on hand disagree. Sizing the card from the frame during that window
    /// makes it crop the picture to a shape it was never taken in, which is the cropped preview
    /// people notice after moving or resizing something. Sizing it from the image means the
    /// card simply reshapes when the new preview arrives, and nothing is ever cut.
    static func aspectRatio(image: CGSize?, windowAspect: CGFloat) -> CGFloat {
        guard let image, image.width > 0, image.height > 0 else { return windowAspect }
        return image.width / image.height
    }

    static func height(width: CGFloat, aspectRatio: CGFloat) -> CGFloat {
        guard aspectRatio > 0 else { return width * maxHeightRatio }
        return min(max(width / aspectRatio, minHeight), width * maxHeightRatio)
    }

    /// The card a window of this shape gets, fitted inside the strip's width and the height cap.
    ///
    /// A tall window needs more height than the cap allows, and a card draws its preview `.fill`,
    /// so holding the width fixed would cut the bottom off the page — 22% of it for a 500x867
    /// browser window. Stage Manager itself never cuts a window: it keeps the shape and lets a
    /// tall window take a slimmer card, which is what happens here. Only a window wider than
    /// `width / minHeight` is still cropped, because preserving its shape would need a card
    /// wider than the strip.
    static func size(width: CGFloat, aspectRatio: CGFloat) -> CGSize {
        let height = height(width: width, aspectRatio: aspectRatio)
        guard aspectRatio > 0 else { return CGSize(width: width, height: height) }
        return CGSize(width: min(width, height * aspectRatio), height: height)
    }

    /// How much of the picture the card cuts off, 0 for none and 0.25 for a quarter.
    ///
    /// A card draws its preview `.fill`, so whenever the clamps above stop it from taking the
    /// picture's own shape the difference is cut away rather than letterboxed. This says by
    /// how much, so a crop can be measured instead of guessed at.
    static func cropFraction(image: CGSize, width: CGFloat) -> CGFloat {
        guard image.width > 0, image.height > 0, width > 0 else { return 0 }
        let aspect = image.width / image.height
        let card = size(width: width, aspectRatio: aspect)
        guard card.width > 0, card.height > 0 else { return 0 }
        let cardAspect = card.width / card.height
        return abs(cardAspect - aspect) / max(cardAspect, aspect)
    }
}
