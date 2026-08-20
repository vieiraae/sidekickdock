import SwiftUI

enum Theme {
    static let cardCorner: CGFloat = 12
    static let panelCorner: CGFloat = 26
    static let cardSpacing: CGFloat = 16
    static let panelPadding: CGFloat = 14
    /// How much of the strip stays visible when the dock is tucked against the edge.
    /// Must clear the app badge — 24pt wide, inset 7pt from the card's outer edge — or the
    /// icon that identifies a collapsed card gets clipped off the panel.
    static let peek: CGFloat = 36

    /// Matched against a screenshot of the real Stage Manager: its cards are 145px tall on
    /// the near edge and 134px on the far edge (ratio 0.924), with the near edge being the
    /// one closest to the screen edge. A positive Y rotation brings the leading edge
    /// forward, so a left-hand dock uses a positive angle. Calibrated by rendering
    /// candidate angles offscreen and measuring the same ratio.
    static let tiltRevealed: Double = 9
    static let tiltCollapsed: Double = 15
    static let perspective: CGFloat = 0.5

    static let reveal = Animation.spring(response: 0.42, dampingFraction: 0.84)
    static let hover = Animation.spring(response: 0.3, dampingFraction: 0.74)
    /// Wall-clock budget for `reveal` to settle, used to time the panel resize that
    /// follows the collapse animation. Kept tight, because until it fires the panel is
    /// still full width and will swallow clicks near the screen edge.
    static let revealDuration: TimeInterval = 0.45
}

/// Reliable hover detection for non-key panels, where SwiftUI's `.onHover`
/// can be starved of tracking updates.
struct HoverTracker: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func trackHover(_ onChange: @escaping (Bool) -> Void) -> some View {
        overlay(HoverTracker(onChange: onChange).allowsHitTesting(false))
    }
}
