import AppKit
import ApplicationServices

/// Brings a specific window forward through the Accessibility API.
///
/// Unlike Stage Manager, activating a card here is purely additive: the target window is
/// raised and focused, and every other window is left exactly where it is.
enum WindowActivator {

    private static let queue = DispatchQueue(label: "dock.window-activator", qos: .userInitiated)

    // MARK: - Actions

    static func activate(_ window: ManagedWindow, onUnresolved: (@Sendable () -> Void)? = nil) {
        let pid = window.pid
        // Only when actually hidden: unhide() orders every window of the app forward, on
        // every display, which is precisely the side effect being avoided here.
        if let app = NSRunningApplication(processIdentifier: pid), app.isHidden {
            app.unhide()
        }

        let id = window.id
        let title = window.title
        let frame = window.frame

        queue.async {
            guard let element = axWindow(pid: pid, windowID: id, title: title, frame: frame) else {
                // Without a resolved element nothing can be raised, and activating the app
                // would just surface whichever window it considers frontmost.
                DebugLog.log("activate: skipped, window \(id) unresolved")
                // The window is gone even though a card still shows it. Say so, rather than
                // leaving a card that silently swallows every click.
                onUnresolved?()
                return
            }

            // Read before anything moves: naming the window losing focus is what lets the
            // window server handle a switch between two windows of the same app itself.
            let previouslyFocused = AXWindowID.focusedWindow(pid: pid)

            setBool(element, kAXMinimizedAttribute, false)

            // Deliberately no kAXMain / kAXFocused writes: measured, they make an app more
            // likely to raise a sibling window on another display, not less.

            // Deliberately no AXRaise. Focusing the window through the window server already
            // brings it to the front of its own display, whereas AXRaise asks the *app* to
            // raise it — and apps run their own window ordering in response, which is how a
            // click on one display ends up raising a sibling window on another.
            if SkyLight.focusWithoutRaising(pid: pid, windowID: id, replacing: previouslyFocused) { return }

            // Without the window server, raising and activating is all that is left.
            DebugLog.log("activate: SkyLight unavailable, falling back to app activation")
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            }
        }
    }

    static func minimize(_ window: ManagedWindow) {
        perform(on: window) { element in
            setBool(element, kAXMinimizedAttribute, true)
        }
    }

    static func close(_ window: ManagedWindow) {
        perform(on: window) { element in
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
                  let button, CFGetTypeID(button) == AXUIElementGetTypeID()
            else { return }
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Enters or leaves full screen. `AXFullScreen` is not in the public constants but is
    /// what the window itself exposes; pressing the green button is the fallback for apps
    /// that do not publish the attribute.
    static func toggleFullScreen(_ window: ManagedWindow) {
        perform(on: window) { element in
            var current: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &current) == .success,
               let flag = current as? Bool {
                AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, !flag as CFTypeRef)
                return
            }

            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXFullScreenButton" as CFString, &button) == .success,
                  let button, CFGetTypeID(button) == AXUIElementGetTypeID()
            else {
                DebugLog.log("fullscreen: no attribute or button on #\(window.id)")
                return
            }
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Moves and resizes a window.
    ///
    /// Position is set before size and then again afterwards: an app that constrains its
    /// minimum size can push the window off the tile while it resizes, and the second write
    /// puts it back. The rect is in CoreGraphics coordinates, matching `ManagedWindow.frame`.
    static func setFrame(_ frame: CGRect, for window: ManagedWindow) {
        perform(on: window) { element in
            var origin = frame.origin
            var size = frame.size
            let position = AXValueCreate(.cgPoint, &origin)
            let dimensions = AXValueCreate(.cgSize, &size)

            if let position {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
            }
            if let dimensions {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dimensions)
            }
            if let position {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
            }
        }
    }

    static func quitApp(_ window: ManagedWindow) {
        NSRunningApplication(processIdentifier: window.pid)?.terminate()
    }

    /// Orders a window to the front without touching focus.
    ///
    /// This is the one place `AXRaise` is wanted. It asks the *app* to reorder its windows,
    /// which is exactly the side effect `activate` goes out of its way to avoid — but here
    /// bringing the app's other windows forward is the whole point.
    static func raise(_ window: ManagedWindow) {
        perform(on: window) { element in
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }

    /// Resolves the window off the main thread, then runs `body` on it. Accessibility calls
    /// can block for as long as the target app takes to answer, so they never run inline.
    private static func perform(on window: ManagedWindow, _ body: @escaping (AXUIElement) -> Void) {
        let pid = window.pid
        let id = window.id
        let title = window.title
        let frame = window.frame
        queue.async {
            guard let element = axWindow(pid: pid, windowID: id, title: title, frame: frame) else { return }
            body(element)
        }
    }

    // MARK: - Lookup

    /// Finds the AXUIElement for a window. The window ID is the only exact match; title and
    /// frame are fallbacks for apps whose elements do not expose an ID. Returns nil rather
    /// than guessing, because acting on the wrong window is worse than doing nothing.
    private static func axWindow(
        pid: pid_t,
        windowID: CGWindowID,
        title: String,
        frame: CGRect
    ) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        // Without a cap, one unresponsive app would stall every later action on this queue.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty
        else { return nil }

        for element in windows where AXWindowID.of(element) == windowID {
            return element
        }

        // Both fallbacks demand a *unique* match. Two windows of one app routinely share a
        // title — two Finder windows on the same folder, two untitled documents — and picking
        // the first would mean closing or minimising a window the user never pointed at.
        if !title.isEmpty {
            let matches = windows.filter { stringValue($0, kAXTitleAttribute) == title }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                DebugLog.log("activate: ambiguous title '\(title)' for #\(windowID), \(matches.count) matches")
            }
        }

        let byFrame = windows.filter { axFrame($0) == frame }
        if byFrame.count == 1 { return byFrame[0] }

        DebugLog.log("activate: no AX match for #\(windowID) '\(title)'")
        return nil
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue
        else { return nil }

        // Checked rather than force-cast: an app is free to answer with something that is not
        // an AXValue, and a force cast would take the whole dock down with it.
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func setBool(_ element: AXUIElement, _ attribute: String, _ newValue: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString, newValue as CFTypeRef)
    }
}
