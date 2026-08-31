import Foundation

/// Decides which idle ticks are allowed to refresh previews.
///
/// The strip peeks at the screen edge rather than hiding, so it stays on screen and every new
/// thumbnail costs a ScreenCaptureKit capture per window *and* a CoreAnimation commit to
/// redraw it. Sampling showed that redraw to be the largest single cost at rest, all of it
/// spent animating previews a few pixels wide that nobody is looking at.
///
/// What it throttles is *refreshes*. A window nobody has captured yet draws as a grey
/// placeholder, and holding that back conserves nothing — the capture is owed either way, and
/// waiting only means the user looks at empty cards first. Measured before this distinction
/// existed: every launch showed placeholders for 4.8s, four ticks at 1.4s.
struct CaptureThrottle {

    /// Ticks between refreshes while nothing is revealed. Previews then age by at most
    /// ~5.6s, which is invisible at peek size and four times cheaper.
    let every: Int
    private var tick = 0

    init(every: Int = 4) {
        self.every = every
    }

    /// - Parameters:
    ///   - boosted: A strip is revealed, so previews are actually being looked at.
    ///   - hasUnattempted: Some window on screen has never had a capture asked for.
    mutating func shouldCapture(boosted: Bool, hasUnattempted: Bool) -> Bool {
        guard !boosted else { return true }
        if hasUnattempted {
            tick = 0
            return true
        }
        tick += 1
        guard tick >= every else { return false }
        tick = 0
        return true
    }
}
