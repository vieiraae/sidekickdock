import Foundation
import CoreGraphics

/// Decides which previews stay frozen.
///
/// A preview is pinned the moment the user minimises a window, because both the minimise and
/// the restore are animations a capture can land in the middle of — leaving the card showing
/// the window smeared into the Dock rather than the window itself.
enum PreviewPins {

    /// How long a pin holds no matter what the rest of the world says.
    ///
    /// The obvious rule — hold the pin while the window is minimised — releases it
    /// immediately, because in the moment after the click the window is not minimised yet
    /// (Accessibility has not caught up) and has not moved yet (the genie has not started).
    /// The very next capture then overwrites the good preview with the exact smear the pin
    /// exists to prevent. The animation runs about 0.7s; this covers it with room to spare.
    static let grace: TimeInterval = 1.5

    /// The pins that survive this tick, keyed by the moment each was taken.
    ///
    /// - `presentMinimised`: every window currently in the list, and whether it is minimised.
    /// - `unsettled`: windows whose frame is still changing, which includes one being restored.
    ///
    /// Once the grace expires a pin is released only when its window is back on screen *and*
    /// still: letting go as soon as the window stops being minimised would hand the restore
    /// animation the same opening the minimise had. A window that has gone altogether drops
    /// its pin — but only after the grace, since mid-animation it can be missing from the
    /// list for a tick or two.
    static func retained(
        _ pins: [CGWindowID: Date],
        presentMinimised: [CGWindowID: Bool],
        unsettled: Set<CGWindowID>,
        now: Date = Date()
    ) -> [CGWindowID: Date] {
        pins.filter { id, taken in
            if now.timeIntervalSince(taken) < grace { return true }
            guard let isMinimized = presentMinimised[id] else { return false }
            return isMinimized || unsettled.contains(id)
        }
    }
}
