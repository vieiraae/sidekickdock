import AppKit
import Combine

/// Single source of truth for the window list and its live previews.
@MainActor
final class WindowStore: ObservableObject {
    static let shared = WindowStore()

    @Published private(set) var windows: [ManagedWindow] = []
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    /// Displays whose active window fills the screen, where the dock must stay out of the
    /// way entirely.
    @Published private(set) var fullScreenDisplays: Set<CGDirectDisplayID> = []

    /// Stable slot per window, assigned once when the window is first seen and never
    /// revised afterwards. Activating a card must not shuffle the strip, so newly
    /// discovered windows simply append below the existing ones.
    private var order: [CGWindowID: UInt64] = [:]
    private var nextSlot: UInt64 = 0
    private var displayAssignments: [CGWindowID: CGDirectDisplayID] = [:]
    /// Slots and display assignments outlive brief disappearances (Space switches, for
    /// example) so a window returns to the same place in the strip instead of the bottom.
    private var lastSeen: [CGWindowID: Date] = [:]
    /// The previous tick's on-screen set, used to notice the moment a window leaves the
    /// screen so its minimised/closed state can be resolved without a stale cache.
    private var lastOnScreenIDs: Set<CGWindowID> = []
    /// Windows caught mid-restore, held briefly so the card does not blink out.
    private var restoring: [CGWindowID: (window: ManagedWindow, since: Date)] = [:]
    /// Backstops only: both graces normally end the moment the Accessibility API settles
    /// the question, so these just stop a window lingering forever if it never does.
    private let restoreGrace: TimeInterval = 6
    /// Windows caught mid-minimise, held as minimised until the Accessibility API agrees.
    private var vanishing: [CGWindowID: (window: ManagedWindow, since: Date)] = [:]
    private let vanishGrace: TimeInterval = 3
    /// Windows whose restore grace ran out without them ever reappearing. Kept so the vanish
    /// grace cannot adopt them and start the cycle again; cleared if the window comes back.
    private var expiredRestores: Set<CGWindowID> = []
    /// Each window's frame as of the previous tick, used to notice motion.
    private var lastFrames: [CGWindowID: CGRect] = [:]
    /// The last frame each window reported while it was demonstrably still, used in place
    /// of an in-flight one.
    private var settledFrames: [CGWindowID: CGRect] = [:]
    private let forgetAfter: TimeInterval = 120
    /// Windows whose preview is frozen at the frame it held just before it was minimised.
    ///
    /// The minimise genie is a capture hazard: Accessibility does not report `isMinimized`
    /// until part way through it, and a capture started before the click can land in the
    /// middle of it. Either way the retained preview becomes a smear of the window being
    /// sucked into the Dock — which is then what the dimmed card shows for as long as the
    /// window stays minimised. Pinning at the moment of the click keeps the last good frame.
    private var pinnedPreviews: [CGWindowID: Date] = [:]

    private let engine = ThumbnailEngine()
    private var loop: Task<Void, Never>?
    private var captureInFlight = false
    /// A tick is in progress. It suspends while the window list is enumerated off the main
    /// actor, and a second tick entering during that window would recompute the graces from
    /// an already-stale `windows` and then overwrite the first one's result — which shows up
    /// as cards blinking or a closed window coming back. Actions request a tick constantly
    /// (every click, every minimise, every reveal), so this is reached routinely.
    private var tickInFlight = false
    private var tickAgain = false
    private var boostCount = 0

    private var idleInterval: TimeInterval { 1.4 }
    private var throttle = CaptureThrottle()
    /// Windows a capture has already been asked for. Distinguishes "no preview yet" from
    /// "no preview possible", so only the former is worth breaking the idle throttle for.
    private var previewAttempted: Set<CGWindowID> = []
    private var activeInterval: TimeInterval { 0.5 }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = self.boostCount > 0 ? self.activeInterval : self.idleInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Whether this tick should refresh previews while nothing is revealed.
    private func shouldCaptureWhileIdle(for current: [ManagedWindow]) -> Bool {
        let unattempted = current.contains {
            !$0.isMinimized && !previewAttempted.contains($0.id)
        }
        return throttle.shouldCapture(boosted: boostCount > 0, hasUnattempted: unattempted)
    }

    /// Called while a dock panel is revealed, to raise the preview refresh rate.
    func beginBoost() {
        boostCount += 1
        // The strip is about to be looked at, so the relaxed idle scan age must not carry
        // over into it.
        MinimizedScanner.invalidate()
        Task { await tick(force: true) }
    }

    func endBoost() {
        boostCount = max(0, boostCount - 1)
    }

    // MARK: - Queries

    func windows(on displayID: CGDirectDisplayID) -> [ManagedWindow] {
        let onDisplay = windows.filter { displayAssignments[$0.id] == displayID }

        // Windows of one app sit together. Each app takes the slot of its earliest window,
        // so grouping never overrides slot stability: a second window opening later joins
        // its siblings rather than landing at the bottom, and nothing moves on a click.
        var groupSlot: [pid_t: UInt64] = [:]
        for window in onDisplay {
            let slot = order[window.id] ?? .max
            if let existing = groupSlot[window.pid], existing <= slot { continue }
            groupSlot[window.pid] = slot
        }

        return onDisplay.sorted { lhs, rhs in
            let lg = groupSlot[lhs.pid] ?? .max
            let rg = groupSlot[rhs.pid] ?? .max
            if lg != rg { return lg < rg }
            let l = order[lhs.id] ?? .max
            let r = order[rhs.id] ?? .max
            if l == r { return lhs.id < rhs.id }
            return l < r
        }
    }

    /// The other windows sharing `window`'s display, frontmost first, for the Fill & Arrange
    /// tiles. Minimised windows are skipped: an arrangement should only move what is visible.
    func arrangementNeighbours(of window: ManagedWindow) -> [ManagedWindow] {
        guard let display = displayAssignments[window.id] else { return [] }
        return windows
            .filter {
                displayAssignments[$0.id] == display
                    && $0.id != window.id
                    && !$0.isMinimized
                    && $0.zIndex != .max
            }
            // Lower zIndex is further forward: CoreGraphics lists windows front to back.
            .sorted { $0.zIndex < $1.zIndex }
    }

    /// One display's worth of windows for the switcher.
    struct DisplayGroup: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let isPrimary: Bool
        let windows: [ManagedWindow]
    }

    /// The switcher shows exactly what the strips show, display by display: external displays
    /// first and the primary last, each in the strip's own app-grouped slot order. Reusing
    /// `windows(on:)` means the switcher can never disagree with the dock about ordering.
    func switcherGroups() -> [DisplayGroup] {
        let screens = NSScreen.screens.sorted { lhs, rhs in
            let lp = lhs.frame.origin == .zero
            let rp = rhs.frame.origin == .zero
            if lp != rp { return !lp }
            // Stable beyond the primary: left to right.
            return lhs.frame.minX < rhs.frame.minX
        }

        return screens.compactMap { screen in
            let id = ScreenGeometry.displayID(of: screen)
            let windows = windows(on: id)
            guard !windows.isEmpty else { return nil }
            return DisplayGroup(
                id: id,
                name: screen.localizedName,
                isPrimary: screen.frame.origin == .zero,
                windows: windows
            )
        }
    }

    func thumbnail(for window: ManagedWindow) -> NSImage? { thumbnails[window.id] }

    // MARK: - Refresh

    func refreshNow() {
        Task { await tick(force: true) }
    }

    private func tick(force: Bool = false) async {
        guard Permissions.shared.hasScreenRecording else { return }

        guard !tickInFlight else {
            // Coalesce rather than queue: the follow-up only has to happen once.
            tickAgain = true
            return
        }
        tickInFlight = true
        defer {
            tickInFlight = false
            if tickAgain {
                tickAgain = false
                Task { await tick(force: true) }
            }
        }

        let includeMinimized = Preferences.shared.includeMinimized
        let previousOnScreen = lastOnScreenIDs
        // Nothing revealed: let the Accessibility scan go stale for longer. Anything that
        // takes a window off screen — minimising, closing, a Space change — invalidates the
        // cache on its own, so the periodic scan only exists to catch changes that produced
        // no visible change at all.
        let scanMaxAge: TimeInterval = boostCount > 0 ? 2.0 : 8.0
        let snapshot = await Task.detached(priority: .userInitiated) {
            WindowEnumerator.snapshot(
                includeMinimized: includeMinimized,
                previousOnScreenIDs: previousOnScreen,
                scanMaxAge: scanMaxAge
            )
        }.value
        let fresh = snapshot.windows
        lastOnScreenIDs = Set(fresh.lazy.filter { !$0.isMinimized }.map(\.id))
        // A window that genuinely came back is eligible for the graces again.
        if !expiredRestores.isEmpty {
            expiredRestores.subtract(fresh.map(\.id))
        }

        let now = Date()
        var carried = carryRestoringWindows(into: fresh, snapshot: snapshot, now: now)
        carried = carryVanishingWindows(into: carried, snapshot: snapshot, now: now)

        var resolved: [ManagedWindow] = []
        var unsettled: Set<CGWindowID> = []
        resolved.reserveCapacity(carried.count)

        for window in carried {
            lastSeen[window.id] = now
            if order[window.id] == nil {
                order[window.id] = nextSlot
                nextSlot &+= 1
            }
            // Minimising and restoring are animations, and for their duration CoreGraphics
            // reports the in-flight frame: the wrong size, the wrong aspect ratio, and —
            // since the animation flies to and from the Dock — often the wrong display.
            // Acting on it throws the card onto another strip and stretches it. A frame is
            // only trustworthy once it has stopped changing, so hold the last still one
            // until then. This covers dragging a window between displays too.
            var entry = window
            var moving = false
            if !window.isMinimized {
                if lastFrames[window.id] == window.frame {
                    settledFrames[window.id] = window.frame
                } else if let known = settledFrames[window.id] {
                    moving = true
                    unsettled.insert(window.id)
                    entry = window.withFrame(known)
                }
                lastFrames[window.id] = window.frame
            }

            if !(moving || window.isMinimized) || displayAssignments[window.id] == nil {
                displayAssignments[window.id] = ScreenGeometry.owningDisplay(for: entry.frame)
            }
            resolved.append(entry)
        }
        let current = resolved

        let remembered = Set(lastSeen.filter { now.timeIntervalSince($0.value) < forgetAfter }.keys)
        lastSeen = lastSeen.filter { remembered.contains($0.key) }
        order = order.filter { remembered.contains($0.key) }
        displayAssignments = displayAssignments.filter { remembered.contains($0.key) }
        lastFrames = lastFrames.filter { remembered.contains($0.key) }
        vanishing = vanishing.filter { remembered.contains($0.key) }
        settledFrames = settledFrames.filter { remembered.contains($0.key) }
        previewAttempted.formIntersection(remembered)
        if thumbnails.keys.contains(where: { !remembered.contains($0) }) {
            thumbnails = thumbnails.filter { remembered.contains($0.key) }
        }

        if let focused = current.first(where: \.isActive) {
            UsageHistory.shared.record(focused.id)
        }
        UsageHistory.shared.prune(keeping: Set(current.map(\.id)))

        if windows != current { windows = current }

        // A pinned preview is released once its window is back on screen *and* still, so the
        // restore animation cannot overwrite it either. Windows that have gone for good drop
        // out with everything else.
        pinnedPreviews = PreviewPins.retained(
            pinnedPreviews,
            presentMinimised: Dictionary(current.map { ($0.id, $0.isMinimized) },
                                         uniquingKeysWith: { a, _ in a }),
            unsettled: unsettled
        )

        let covered = coveredDisplays(in: current)
        if fullScreenDisplays != covered {
            DebugLog.log("displays covered by active window: \(covered.sorted())")
            fullScreenDisplays = covered
        }

        guard force || !captureInFlight else { return }
        guard force || shouldCaptureWhileIdle(for: current) else { return }
        // Capturing mid-animation would replace a good preview with a smear of the genie
        // effect, so leave the retained thumbnail in place until the window settles.
        await captureThumbnails(for: current.filter { !unsettled.contains($0.id) })
    }

    /// Whether a window has genuinely been closed, as opposed to merely being absent from
    /// the on-screen list for a moment. Absence from the Accessibility API only means
    /// "closed" if that app answered at all: an app that hits the messaging timeout reports
    /// no windows whatsoever, and treating that as "every window closed" would empty the
    /// strip of a busy app.
    private func isClosed(_ window: ManagedWindow, in snapshot: WindowEnumerator.Snapshot) -> Bool {
        // A dead app can never answer a probe, so the test below would hold its windows on
        // the strip forever — and clicking them does nothing, because there is no longer a
        // process to ask. If the process is gone, so are its windows.
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else {
            return true
        }
        return snapshot.probedPIDs.contains(window.pid) && !snapshot.liveWindowIDs.contains(window.id)
    }

    /// Minimising is not instantaneous either: CoreGraphics drops the window from the
    /// on-screen list the moment the genie animation starts, but `AXMinimized` does not flip
    /// until it finishes, so for a beat the window belongs to neither set and its card blinks
    /// out. Holding every vanished window would delay closed windows leaving the strip, so
    /// the two are told apart by whether the Accessibility API can still see the window at
    /// all: a closing window is gone from it immediately, a minimising one is not.
    private func carryVanishingWindows(
        into fresh: [ManagedWindow],
        snapshot: WindowEnumerator.Snapshot,
        now: Date
    ) -> [ManagedWindow] {
        let freshIDs = Set(fresh.map(\.id))

        for previous in windows where !previous.isMinimized && !freshIDs.contains(previous.id) {
            guard vanishing[previous.id] == nil, restoring[previous.id] == nil else { continue }
            guard !expiredRestores.contains(previous.id) else { continue }
            guard !isClosed(previous, in: snapshot) else {
                DebugLog.log("dropped \(previous.appName)#\(previous.id) - closed")
                continue
            }
            DebugLog.log("minimise grace \(previous.appName)#\(previous.id)")
            vanishing[previous.id] = (previous.markingMinimized(), now)
        }

        vanishing = vanishing.filter { id, entry in
            !freshIDs.contains(id)
                && !isClosed(entry.window, in: snapshot)
                && now.timeIntervalSince(entry.since) < vanishGrace
        }
        guard !vanishing.isEmpty else { return fresh }
        return fresh + vanishing.values.map(\.window)
    }

    /// Restoring a window from the Dock animates it: for the length of the genie effect
    /// CoreGraphics reports the in-flight frame, which passes over the Dock's display and
    /// bears no relation to where the window will land. Reassigning the card on that frame
    /// throws it onto the wrong strip and then back again. Treat the frame as meaningless
    /// until it stops changing.
    /// Un-minimising is not instantaneous: the Accessibility API reports the window as
    /// restored straight away, but CoreGraphics does not list it on screen until the genie
    /// animation finishes. In between it belongs to neither set, which would blink the card
    /// out of the strip. Hold it in place, already drawn as restored, until it lands.
    private func carryRestoringWindows(
        into fresh: [ManagedWindow],
        snapshot: WindowEnumerator.Snapshot,
        now: Date
    ) -> [ManagedWindow] {
        let freshIDs = Set(fresh.map(\.id))

        for previous in windows where previous.isMinimized && !freshIDs.contains(previous.id) {
            if restoring[previous.id] == nil {
                DebugLog.log("grace start \(previous.appName)#\(previous.id) frame \(previous.frame)")
                restoring[previous.id] = (previous.markingRestored(), now)
            }
        }

        restoring = restoring.filter { id, entry in
            if freshIDs.contains(id) {
                DebugLog.log("grace landed #\(id) after \(String(format: "%.2f", now.timeIntervalSince(entry.since)))s")
                return false
            }
            if isClosed(entry.window, in: snapshot) {
                DebugLog.log("grace ended #\(id) - closed while restoring")
                return false
            }
            if now.timeIntervalSince(entry.since) >= restoreGrace {
                DebugLog.log("grace EXPIRED #\(id) without landing")
                // Remember it. The held copy is drawn as restored, so without this the
                // vanish path immediately treats it as a window that just disappeared,
                // re-minimises it, and the two graces hand the card back and forth for as
                // long as the app is gone.
                expiredRestores.insert(id)
                return false
            }
            return true
        }
        guard !restoring.isEmpty else { return fresh }
        return fresh + restoring.values.map(\.window)
    }

    /// The frontmost visible window on each display.
    ///
    /// The window list is ordered front to back, so the *lowest* zIndex is the one in front
    /// and `.max` marks an unknown position. Every caller goes through here: getting this
    /// comparison backwards silently disables whatever depends on it.
    private func frontWindows(in windows: [ManagedWindow]) -> [CGDirectDisplayID: ManagedWindow] {
        var frontmost: [CGDirectDisplayID: ManagedWindow] = [:]
        for window in windows where !window.isMinimized && window.zIndex != .max {
            guard let display = displayAssignments[window.id] else { continue }
            if let existing = frontmost[display], existing.zIndex <= window.zIndex { continue }
            frontmost[display] = window
        }
        return frontmost
    }

    /// Displays whose frontmost window fills the screen, where the dock would sit on top of
    /// content the user has deliberately given the whole display to.
    ///
    /// Frame coverage is the test rather than the Accessibility `AXFullScreen` flag: that
    /// flag only catches native full-screen mode, and a window zoomed to fill the screen
    /// obstructs the dock just as much. Comparing against the *visible* frame covers both,
    /// including notched Macs where a native full-screen window sits below the menu bar and
    /// so is indistinguishable from a zoomed one by geometry alone.
    ///
    /// Judged per display rather than from the single globally-active window: with more than
    /// one display the frontmost window overall says nothing about what covers the others,
    /// and some apps raise a sibling on another display when activated, which would
    /// otherwise make this measure the wrong window entirely.
    private func coveredDisplays(in windows: [ManagedWindow]) -> Set<CGDirectDisplayID> {
        let frontmost = frontWindows(in: windows)

        var covered: Set<CGDirectDisplayID> = []
        // A display showing a full-screen Space has nothing worth listing: its window is in a
        // Space of its own and never appears in the enumeration, so the strip would show only
        // whatever else that app left behind.
        let fullScreen = SpaceInspector.fullScreenDisplays()
        covered.formUnion(fullScreen)
        if DebugLog.isEnabled, !fullScreen.isEmpty {
            DebugLog.log("full-screen spaces on displays \(fullScreen.sorted())")
        }

        for (display, window) in frontmost {
            guard let screen = ScreenGeometry.screen(for: display) else { continue }
            let visible = ScreenGeometry.cgVisibleFrame(of: screen)
            let tolerance: CGFloat = 4
            let fills = window.frame.minX <= visible.minX + tolerance
                && window.frame.minY <= visible.minY + tolerance
                && window.frame.maxX >= visible.maxX - tolerance
                && window.frame.maxY >= visible.maxY - tolerance
            if fills { covered.insert(display) }
        }
        return covered
    }

    private func captureThumbnails(for windows: [ManagedWindow]) async {
        guard !captureInFlight else { return }
        captureInFlight = true
        defer { captureInFlight = false }

        let ids = windows.filter { !$0.isMinimized }.map(\.id)
        guard !ids.isEmpty else { return }
        // Recorded before the attempt, not after a success. Some windows can never be
        // captured — ScreenCaptureKit declines a few — and keying the "no preview yet" bypass
        // off the image itself would have those windows force a capture on every single tick,
        // for ever.
        previewAttempted.formUnion(ids)

        let width = Preferences.shared.cardWidth
        // Resolved here rather than inside the engine: NSScreen belongs to the main actor.
        var scales: [CGWindowID: CGFloat] = [:]
        for id in ids {
            guard let display = displayAssignments[id],
                  let screen = ScreenGeometry.screen(for: display)
            else { continue }
            scales[id] = screen.backingScaleFactor
        }

        // The frames the subjects held going in. A capture pass is not instantaneous — it is a
        // ScreenCaptureKit round trip per window — so a window can start animating part way
        // through it, and the image that comes back is a smear of the genie or of a drag.
        let before = WindowEnumerator.frames(for: Set(ids))

        // A window on a hidden Space cannot be photographed at all: ScreenCaptureKit refuses
        // with -3811, because macOS is not rendering that Space. Asking anyway cost a failed
        // round trip per window on every pass and, worse, a full all-Spaces content query to
        // find them. The card keeps the last preview taken while the window was on screen,
        // which is the truest picture of it that exists.
        let onScreen = ids.filter { before[$0] != nil }
        guard !onScreen.isEmpty else { return }

        let images = await engine.capture(windowIDs: onScreen, targetWidth: width, scales: scales)
        guard !images.isEmpty else { return }

        // Anything that moved, or left the screen, while the pass was running is discarded:
        // the previous preview is a truer picture of the window than a frame of its animation,
        // and for a minimising window it is the *last* picture there will ever be.
        let after = WindowEnumerator.frames(for: Set(images.keys))

        var merged = thumbnails
        for (id, cgImage) in images {
            // A capture in flight when the user hit minimise resolves mid-genie, so a pinned
            // preview has to survive results that were already on their way.
            guard pinnedPreviews[id] == nil else { continue }
            guard let start = before[id], let end = after[id], start == end else {
                DebugLog.log("preview: discarding in-flight capture of #\(id)")
                continue
            }
            guard PreviewPins.shapeMatches(
                image: CGSize(width: cgImage.width, height: cgImage.height),
                window: end.size
            ) else {
                DebugLog.log("preview: discarding misshapen capture of #\(id)")
                continue
            }
            // The point size must undo the same scale the capture applied, or the preview
            // draws at the wrong size on a non-Retina display.
            let backing = scales[id] ?? 2
            let size = NSSize(width: CGFloat(cgImage.width) / backing,
                              height: CGFloat(cgImage.height) / backing)
            let crop = CardGeometry.cropFraction(image: size, width: CGFloat(Preferences.shared.cardWidth))
            if crop > 0.02 {
                DebugLog.log(String(format: "preview: #%d %.0fx%.0f will be cropped by %.0f%%",
                                    id, size.width, size.height, crop * 100))
            }
            merged[id] = NSImage(cgImage: cgImage, size: size)
        }
        thumbnails = merged
    }

    // MARK: - Intent

    /// Brings a window forward, additively: nothing else is minimised, hidden, or reordered.
    func activate(_ window: ManagedWindow) {
        // Recorded up front rather than waiting for the next tick to observe the focus
        // change: a ⌘Tab commit is followed immediately by another ⌘Tab often enough that
        // the history has to be right before the refresh lands.
        UsageHistory.shared.record(window.id)
        DebugLog.log("click -> \(window.appName)#\(window.id) '\(window.title)'")
        WindowActivator.activate(window) {
            Task { @MainActor in WindowStore.shared.forget(window.id) }
        }
        MinimizedScanner.invalidate()
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            await tick(force: true)
        }
    }

    func minimize(_ window: ManagedWindow) {
        // Freeze the preview before the genie starts, so the card keeps the window as it
        // actually looked rather than mid-flight into the Dock.
        pinnedPreviews[window.id] = Date()

        // Minimising the frontmost app's front window makes macOS promote that app's *next*
        // window to key, and that window is often on another display — so a sibling appears
        // to leap onto the other screen. Handing focus to the display's next window first
        // means the app is no longer frontmost when it loses the window, so it promotes
        // nothing. Measured: minimising Edge#9459 on d5 pulled Edge#9462 to the front of d1.
        if let successor = minimizeSuccessor(for: window) {
            DebugLog.log("minimize: pre-focusing \(successor.appName)#\(successor.id)")
            WindowActivator.activate(successor)
        }

        WindowActivator.minimize(window)
        MinimizedScanner.invalidate()
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            await tick(force: true)
        }
    }

    /// The window that should take focus before `window` is minimised, or nil when nothing
    /// needs to happen.
    ///
    /// Only relevant when the target belongs to the frontmost app *and* is the top window on
    /// its display — that is the one case where minimising leaves the app looking for a new
    /// key window. The successor must belong to a different app, since the whole point is to
    /// stop the target's app being frontmost at the moment it loses the window.
    private func minimizeSuccessor(for window: ManagedWindow) -> ManagedWindow? {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontPID == window.pid, let display = displayAssignments[window.id] else { return nil }

        let onDisplay = windows.filter {
            displayAssignments[$0.id] == display && !$0.isMinimized && $0.zIndex != .max
        }
        // Lowest zIndex is furthest forward; `frontWindows` owns that convention.
        guard frontWindows(in: windows)[display]?.id == window.id else { return nil }

        return onDisplay
            .filter { $0.pid != window.pid }
            .min(by: { $0.zIndex < $1.zIndex })
    }

    func close(_ window: ManagedWindow) {
        WindowActivator.close(window)
        MinimizedScanner.invalidate()
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            await tick(force: true)
        }
    }

    func toggleFullScreen(_ window: ManagedWindow) {
        WindowActivator.toggleFullScreen(window)
        Task {
            // Longer than the others: the full-screen transition is a Space change, and the
            // window reports its old frame until the animation finishes.
            try? await Task.sleep(for: .milliseconds(900))
            await tick(force: true)
        }
    }

    func quitApp(_ window: ManagedWindow) {
        WindowActivator.quitApp(window)
    }

    /// Removes a window the strip still shows but that no longer exists. Called when an
    /// activation cannot resolve it, so a stale card cannot sit there swallowing clicks.
    func forget(_ id: CGWindowID) {
        guard windows.contains(where: { $0.id == id }) else { return }
        DebugLog.log("forget #\(id) - gone on click")
        restoring[id] = nil
        vanishing[id] = nil
        expiredRestores.insert(id)
        windows.removeAll { $0.id == id }
    }

    /// Every window of the app that could be brought forward — the clicked one included.
    /// Minimised windows are excluded: they cannot be raised without restoring them, and
    /// silently un-minimising is a bigger action than this menu item promises.
    func raisableSiblings(of window: ManagedWindow) -> [ManagedWindow] {
        windows.filter { $0.pid == window.pid && !$0.isMinimized }
    }

    /// Mirrors the Dock's "Show All Windows", across every display. Still additive, like a
    /// normal click: no other app is minimised or hidden.
    func showAllWindows(_ window: ManagedWindow) {
        // Back to front, so the app's own relative ordering survives, with the clicked
        // window raised last so it ends up on top and focused.
        let others = raisableSiblings(of: window)
            .filter { $0.id != window.id }
            .sorted { $0.zIndex > $1.zIndex }
        for sibling in others {
            WindowActivator.raise(sibling)
        }
        activate(window)
    }
}
