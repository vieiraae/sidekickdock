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
    /// When each window was last asked about. Not every question gets an answer — an app can
    /// list a window in CoreGraphics that never appears in its own Accessibility list — and
    /// without this such a window asked again on every single tick, which meant an
    /// Accessibility sweep of its app every tick for as long as it existed. Measured: 243
    /// consecutive sweeps over three minutes for one Chromium surface.
    private nonisolated(unsafe) static var askedAt: [CGWindowID: Date] = [:]
    /// How long an unanswered window waits before it is asked about again. Short enough that
    /// an app which was simply slow to publish a window is judged within a few seconds, long
    /// enough that one that never will costs a sweep every few seconds instead of every tick.
    static let retryAfter: TimeInterval = 5

    /// How long a window judged *not real* keeps that verdict before it is asked about again.
    ///
    /// A verdict used to be final for as long as the window existed, and that made a single
    /// wrong answer permanent: a window that answered `AXUnknown` while it was still being
    /// built — which Chromium windows do — stayed invisible until the dock was restarted,
    /// days later. The two mistakes are not equally bad. An extra card is visible and
    /// short-lived, because the surfaces this filter exists for are dismissed in seconds; a
    /// missing card is silent and, without this, permanent. So a negative is a working
    /// assumption with an expiry rather than a fact, and only "this is a real window" is
    /// remembered for good.
    static let recheckAfter: TimeInterval = 30

    /// The windows worth asking about.
    ///
    /// A window already known to be real is never asked about again. One judged unreal is
    /// asked again once its verdict has aged out, and one that has never been answered for is
    /// retried sooner, since an app may simply have been slow to publish it.
    static func needsProbing(
        windows: [CGWindowID],
        verdicts: [CGWindowID: Bool] = [:],
        askedAt: [CGWindowID: Date],
        now: Date = Date(),
        retryAfter: TimeInterval = retryAfter,
        recheckAfter: TimeInterval = recheckAfter
    ) -> Set<CGWindowID> {
        Set(windows.filter { id in
            switch verdicts[id] {
            case true?:
                return false
            case false?:
                guard let asked = askedAt[id] else { return true }
                return now.timeIntervalSince(asked) >= recheckAfter
            case nil:
                guard let asked = askedAt[id] else { return true }
                return now.timeIntervalSince(asked) >= retryAfter
            }
        })
    }

    /// Drops the windows Accessibility says are not real windows.
    ///
    /// Fails open: if Accessibility is unavailable, an app does not answer, or a window is
    /// simply not in its app's window list, the window is kept. A missing preview is a far
    /// worse failure than an extra card, and this runs on every refresh.
    static func filtering(_ windows: [ManagedWindow]) -> [ManagedWindow] {
        guard AXIsProcessTrusted(), AXWindowID.isAvailable else { return windows }

        lock.lock()
        var known = verdicts
        var asked = askedAt
        lock.unlock()

        let now = Date()
        let wanted = needsProbing(
            windows: windows.map(\.id), verdicts: known, askedAt: asked, now: now
        )
        for pid in Set(windows.filter { wanted.contains($0.id) }.map(\.pid)) {
            for (id, isReal) in probe(pid: pid) {
                // A window we asked about takes the fresh answer, even over an existing
                // verdict — that is the whole point of asking again. Others are only filled
                // in where nothing is known, so a window this app happens to list is judged
                // without a sweep of its own.
                guard wanted.contains(id) || known[id] == nil else { continue }
                if known[id] == false, isReal {
                    DebugLog.log("snapshot: #\(id) is a real window after all, showing it")
                }
                known[id] = isReal
            }
        }
        for id in wanted { asked[id] = now }

        // Only windows that are still around are worth remembering: window IDs are never
        // reused, so an unpruned cache would grow for as long as the app runs.
        let present = Set(windows.map(\.id))
        lock.lock()
        verdicts = known.filter { present.contains($0.key) }
        askedAt = asked.filter { present.contains($0.key) }
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
