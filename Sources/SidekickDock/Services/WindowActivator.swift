import AppKit
import ApplicationServices

/// Brings a specific window forward through the Accessibility API.
///
/// Unlike Stage Manager, activating a card here is purely additive: the target window is
/// raised and focused, and every other window is left exactly where it is.
enum WindowActivator {

    private static let queue = DispatchQueue(label: "dock.window-activator", qos: .userInitiated)

    /// Identifies the most recent activation request. A correction belonging to an older
    /// request is dropped, so a retry can never fight a window the user has since clicked.
    private static let generationLock = NSLock()
    private static var generation = 0

    private static func nextGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation += 1
        return generation
    }

    private static func isCurrent(_ value: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == value
    }

    // MARK: - Actions

    static func activate(_ window: ManagedWindow, onUnresolved: (@Sendable () -> Void)? = nil) {
        let generation = nextGeneration()
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
                // Failing to resolve an element means the *question* failed, which is not the
                // same as the window being gone: Accessibility can be revoked, time out, or
                // have the app answer late. Treating those as "gone" deleted the card the
                // user had just clicked, so the window server is asked before anything is
                // removed — it is the only authority on whether a window still exists.
                if WindowEnumerator.frames(for: [id]).isEmpty {
                    DebugLog.log("activate: window \(id) is gone, dropping its card")
                    onUnresolved?()
                    return
                }

                // The window is still on screen and only the Accessibility handle is missing.
                // Focusing through the window server needs no handle at all, so the click
                // still does what the user asked. `replacing:` is left nil deliberately: it
                // only refines the same-app case, and reading it needs the Accessibility that
                // just failed.
                DebugLog.log("activate: #\(id) unresolved but still on screen, using window server")
                if !SkyLight.focusWithoutRaising(pid: pid, windowID: id, replacing: nil) {
                    DispatchQueue.main.async {
                        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
                    }
                }
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
            if SkyLight.focusWithoutRaising(pid: pid, windowID: id, replacing: previouslyFocused) {
                confirmRaise(of: element, pid: pid, windowID: id, generation: generation)
                return
            }

            // Without the window server, raising and activating is all that is left.
            DebugLog.log("activate: SkyLight unavailable, falling back to app activation")
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
            }
        }
    }

    /// Checks that the window really did come forward, and corrects it when it did not.
    ///
    /// The window server accepts the focus request and reports success even when it does not
    /// raise the window. Measured across runs it failed anywhere between 1 click in 12 and 8
    /// in 16, depending on the app and on which window was in front; nothing in the return
    /// codes or the ordering of the calls distinguishes a failure from a success. The only
    /// reliable signal is the result, so the result is what gets checked.
    ///
    /// A failure never repairs itself: measured at 120ms, 300ms, 600ms and 1s after the
    /// request, a window that had not come forward was still buried at every one of them.
    /// Repeating the same window-server call does not help either — it was tried first and
    /// corrected nothing — so the correction goes straight to `AXRaise`.
    ///
    /// `AXRaise` is otherwise avoided here, because asking the *app* to raise a window makes
    /// it reorder its own windows on other displays. It is the right trade only because the
    /// alternative is a click that visibly does nothing.
    private static func confirmRaise(
        of element: AXUIElement,
        pid: pid_t,
        windowID: CGWindowID,
        generation: Int
    ) {
        queue.asyncAfter(deadline: .now() + 0.12) {
            guard isCurrent(generation), isBuried(windowID: windowID, pid: pid) else { return }
            DebugLog.log("activate: #\(windowID) did not come forward, raising it")
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }

    /// True when another app's window is drawn over this one.
    ///
    /// Only windows belonging to *other* apps count. An app's own windows sitting above the
    /// target — a sheet, a dialog, a floating palette — are its own business, and treating
    /// them as failures would mean re-raising the parent out from under its own dialog.
    private static func isBuried(windowID: CGWindowID, pid: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return false }

        func bounds(_ entry: [String: Any]) -> CGRect? {
            guard let raw = entry[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: raw)
        }

        guard let target = list.first(where: { $0[kCGWindowNumber as String] as? CGWindowID == windowID }),
              let frame = bounds(target), !frame.isEmpty
        else {
            // Not on screen at all: minimised, closed, or moved to another Space while the
            // check was in flight. Nothing to correct.
            return false
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for entry in list {
            // The list is front to back, so reaching the target means nothing covers it.
            if entry[kCGWindowNumber as String] as? CGWindowID == windowID { return false }
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let otherPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  otherPID != pid, otherPID != ownPID,
                  let other = bounds(entry), other.intersects(frame)
            else { continue }
            return true
        }
        return false
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
