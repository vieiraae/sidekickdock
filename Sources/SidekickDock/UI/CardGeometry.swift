import CoreGraphics

/// How tall a card is for a given preview.
enum CardGeometry {

    /// A card is never thinner than this, however wide its window is.
    static let minHeight: CGFloat = 58
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
}
