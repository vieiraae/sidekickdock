import CoreGraphics

/// How the strip arranges the cards it is given.
///
/// Kept out of the view so the rules can be tested: which card sits where is the part of the
/// dock people notice, and it has to stay predictable while windows come and go.
enum StripLayout {

    /// The windows of one app, front to back, drawn as an overlapping stack.
    struct Stack: Identifiable {
        let pid: pid_t
        /// Frontmost first, matching `windows`' own order.
        let windows: [ManagedWindow]

        /// The identity of the stack is its app, not its contents: keeping it stable is what
        /// lets a window join or leave a stack without the whole group being torn down and
        /// rebuilt — which would flash every card in it.
        var id: pid_t { pid }
        /// Back to front, which is the order they are drawn in: each card is laid over the one
        /// before it, so the frontmost window ends up on top.
        var backToFront: [ManagedWindow] { windows.reversed() }
    }

    /// The strip's order: apps in the order they were first seen, each app's windows front to
    /// back inside it.
    ///
    /// The app's place comes from `appSlot` rather than from its windows, because a window's
    /// identity is not as solid as it looks. Terminal keeps more than one window object for
    /// what the user sees as one window, and minimising and restoring hands the visible one to
    /// a different object each time — so an order derived from window IDs walked the app down
    /// the strip every time its window was minimised and brought back.
    ///
    /// Nothing here moves on a click except the order *within* one app, which is the stack's
    /// own depth.
    static func ordered(
        _ windows: [ManagedWindow],
        appSlot: [pid_t: UInt64],
        windowSlot: [CGWindowID: UInt64]
    ) -> [ManagedWindow] {
        windows.sorted { lhs, rhs in
            let la = appSlot[lhs.pid] ?? .max
            let ra = appSlot[rhs.pid] ?? .max
            if la != ra { return la < ra }
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
            let l = windowSlot[lhs.id] ?? .max
            let r = windowSlot[rhs.id] ?? .max
            if l == r { return lhs.id < rhs.id }
            return l < r
        }
    }

    /// Splits an already ordered list into one stack per app.
    ///
    /// Consecutive runs rather than a dictionary: `WindowStore` has already placed each app's
    /// windows together in the order the strip wants them, and re-grouping here would throw
    /// that away.
    static func stacks(_ windows: [ManagedWindow]) -> [Stack] {
        var stacks: [Stack] = []
        var current: [ManagedWindow] = []
        for window in windows {
            if let first = current.first, first.pid != window.pid {
                stacks.append(Stack(pid: first.pid, windows: current))
                current = []
            }
            current.append(window)
        }
        if let first = current.first {
            stacks.append(Stack(pid: first.pid, windows: current))
        }
        return stacks
    }

    /// How much of a card the next card in its stack is allowed to cover.
    ///
    /// Half, so what stays visible is a real piece of the window rather than a sliver of
    /// chrome: the point of stacking is to say an app has several windows *and* to let each
    /// one still be recognised. A floor keeps that true for the short cards a very wide
    /// window gets, where half of very little would be nothing at all.
    static func overlap(cardHeight: CGFloat) -> CGFloat {
        max(cardHeight - max(cardHeight * visibleFraction, minimumVisible), 0)
    }

    /// How far towards the screen edge a card sits, given how many of its app's windows are
    /// in front of it.
    ///
    /// The window at the back of a pile is nearest the edge and each one in front of it steps
    /// away, so the pile leans out of the screen edge as it comes forward — the depth Stage
    /// Manager's stacks have. Capped, because the strip is only so wide: beyond a few windows
    /// the ones at the back simply share the near edge.
    static func stagger(behindFront count: Int) -> CGFloat {
        CGFloat(min(max(count, 0), maximumSteps)) * step
    }

    private static let visibleFraction: CGFloat = 0.5
    private static let minimumVisible: CGFloat = 26
    private static let step: CGFloat = 7
    private static let maximumSteps = 3
}
