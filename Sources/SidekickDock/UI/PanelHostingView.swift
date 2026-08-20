import AppKit
import SwiftUI

/// Hosting view for the dock's panels.
///
/// Two things every floating panel here needs:
///
/// 1. **It takes the first click.** The panel is rarely the key window — the whole point is
///    that it floats over whatever the user is working in — and AppKit otherwise swallows the
///    click that would make an inactive window key, so the first click on a card did nothing.
/// 2. **It owns the cursor.** Nothing was ever setting one, so the cursor the application
///    underneath had installed — an I-beam over text, a resize arrow near a window edge, a
///    pointing hand over a link — simply stayed as the pointer crossed onto the dock. Cursor
///    rects belong to the key window, so the arrow is asserted from a tracking area marked
///    `.activeAlways` instead, which is delivered whether or not the panel is key.
class PanelHostingView<Content: View>: NSHostingView<Content> {

    private var cursorTracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .activeAlways, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTracking = area
    }

    // Every override forwards to `super` first. SwiftUI's `onHover` is driven by these same
    // events through the hosting view, and swallowing them cost the cards their traffic
    // lights: the hover state never became true.
    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        NSCursor.arrow.set()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Some applications reassert their cursor after we have set ours, so claim it on
        // every move rather than only on entry.
        if NSCursor.current != NSCursor.arrow { NSCursor.arrow.set() }
    }
}
