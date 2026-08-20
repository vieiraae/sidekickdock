import AppKit
import ApplicationServices

/// Tells real windows apart from the window-shaped surfaces apps put on screen.
///
/// Chromium browsers draw the address bar's suggestion list as an ordinary window: layer 0,
/// opaque, a few hundred points across, owned by the browser. Nothing in the CoreGraphics
/// list distinguishes it from a second browser window, so it arrived in the strip as a
/// duplicate of the window it was hanging off. Menus, tooltips and popovers from other
/// toolkits do the same thing.
///
/// Accessibility does distinguish them: a real window is an `AXWindow` with a subrole of
/// `AXStandardWindow` (or a dialog), while these surfaces come back as `AXUnknown`. That
/// answer is asked for once per window and remembered, so the common pass — where every
/// window on screen has already been judged — costs nothing.
enum WindowSubroles {

    /// Subroles that belong in the strip. A dialog or a panel is a window the user can be
    /// looking at and want back; `AXUnknown` is furniture.
    private static let real: Set<String> = [
        kAXStandardWindowSubrole as String,
        kAXDialogSubrole as String,
        kAXSystemDialogSubrole as String,
        kAXFloatingWindowSubrole as String
    ]

    /// Whether a subrole is one the strip should show. An unreadable subrole counts as real:
    /// the strip errs towards showing a window it is unsure about.
    static func isReal(subrole: String?) -> Bool {
        guard let subrole else { return true }
        return real.contains(subrole)
    }

    private static let lock = NSLock()
    /// Verdict per window, kept only for windows still on screen.
    private nonisolated(unsafe) static var verdicts: [CGWindowID: Bool] = [:]

    /// Drops the windows Accessibility says are not real windows.
    ///
    /// Fails open: if Accessibility is unavailable, an app does not answer, or a window is
    /// simply not in its app's window list, the window is kept. A missing preview is a far
    /// worse failure than an extra card, and this runs on every refresh.
    static func filtering(_ windows: [ManagedWindow]) -> [ManagedWindow] {
        guard AXIsProcessTrusted(), AXWindowID.isAvailable else { return windows }

        lock.lock()
        var known = verdicts
        lock.unlock()

        let unjudged = windows.filter { known[$0.id] == nil }
        for pid in Set(unjudged.map(\.pid)) {
            for (id, isReal) in probe(pid: pid) where known[id] == nil {
                known[id] = isReal
            }
        }

        // Only windows that are still around are worth remembering: window IDs are never
        // reused, so an unpruned cache would grow for as long as the app runs.
        let present = Set(windows.map(\.id))
        lock.lock()
        verdicts = known.filter { present.contains($0.key) }
        lock.unlock()

        return windows.filter { known[$0.id] ?? true }
    }

    /// Every window the app admits to, and whether each is a real one.
    private static func probe(pid: pid_t) -> [CGWindowID: Bool] {
        let app = AXUIElementCreateApplication(pid)
        // Never let an unresponsive app stall the refresh loop.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [:] }

        var judged: [CGWindowID: Bool] = [:]
        for window in windows {
            guard let id = AXWindowID.of(window) else { continue }
            var subrole: CFTypeRef?
            let name = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success
                ? subrole as? String
                : nil
            judged[id] = isReal(subrole: name)
            if judged[id] == false {
                DebugLog.log("snapshot: ignoring #\(id) (subrole \(name ?? "none"))")
            }
        }
        return judged
    }
}
