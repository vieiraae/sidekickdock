import AppKit
import ApplicationServices

/// Determines which windows are genuinely minimised.
///
/// The CoreGraphics window list cannot tell a minimised window apart from one that simply
/// lives on another Space — both are just "not on screen". Only the Accessibility API knows,
/// so minimised windows are resolved through `kAXMinimizedAttribute` and cached briefly.
enum MinimizedScanner {

    struct Scan {
        /// Windows the Accessibility API reports as minimised.
        var minimized: Set<CGWindowID> = []
        /// Every window that still exists, minimised or not. A window absent from here has
        /// been closed — which is the only reliable way to tell a closing window from one
        /// that is merely part-way through the minimise animation, since `AXMinimized`
        /// does not flip until the animation ends.
        var existing: Set<CGWindowID> = []
        /// Apps whose window list was read successfully. A window missing from `existing`
        /// only means "closed" if its app is in here: an unresponsive app hits the
        /// messaging timeout and reports no windows at all, which must not be mistaken for
        /// every one of its windows having been closed.
        var probedPIDs: Set<pid_t> = []
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached = Scan()
    private nonisolated(unsafe) static var cachedAt: Date = .distantPast
    /// Default freshness. Callers that are not being looked at ask for a longer one: this
    /// scan is a synchronous Accessibility round trip per app plus two per window, which is
    /// the most expensive thing the refresh loop does.
    private static let ttl: TimeInterval = 2.0
    /// Held for the length of a sweep so that two callers arriving at once do the work once
    /// rather than twice. Deliberately not `lock`: `invalidate()` runs on the main thread and
    /// must never wait behind a sweep, which is seconds long when an app is unresponsive.
    private static let sweepGate = NSLock()

    static func minimizedWindowIDs() -> Set<CGWindowID> { scan().minimized }

    static func scan(maxAge: TimeInterval = ttl) -> Scan {
        lock.lock()
        if Date().timeIntervalSince(cachedAt) < maxAge {
            defer { lock.unlock() }
            return cached
        }
        lock.unlock()

        guard AXIsProcessTrusted(), AXWindowID.isAvailable else { return Scan() }

        sweepGate.lock()
        defer { sweepGate.unlock() }
        // Another caller may have swept while this one waited for the gate, in which case
        // its answer is new enough to use.
        lock.lock()
        if Date().timeIntervalSince(cachedAt) < maxAge {
            defer { lock.unlock() }
            return cached
        }
        lock.unlock()

        var result = Scan()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  !app.isTerminated,
                  app.processIdentifier != selfPID
            else { continue }

            let element = AXUIElementCreateApplication(app.processIdentifier)
            // Never let an unresponsive app stall the refresh loop.
            AXUIElementSetMessagingTimeout(element, 0.25)

            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement]
            else { continue }
            result.probedPIDs.insert(app.processIdentifier)

            for window in windows {
                guard let identifier = AXWindowID.of(window) else { continue }
                result.existing.insert(identifier)

                var minimized: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                   let flag = minimized as? Bool, flag {
                    result.minimized.insert(identifier)
                }
            }
        }

        lock.lock()
        cached = result
        cachedAt = Date()
        lock.unlock()
        return result
    }

    static func invalidate() {
        lock.lock()
        cachedAt = .distantPast
        lock.unlock()
    }
}
