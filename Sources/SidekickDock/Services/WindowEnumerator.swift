import AppKit
import CoreGraphics

/// Enumerates real, user-facing windows.
///
/// The on-screen CoreGraphics list is the source of truth: it contains exactly the windows
/// visible on the Spaces currently shown across all displays, which is the same set Stage
/// Manager works from. Minimised windows are added separately, and only after the
/// Accessibility API confirms they really are minimised — the raw `.optionAll` list is
/// unusable on its own because it also returns other-Space windows plus hundreds of stale,
/// never-displayed helper surfaces whose bogus frames land on the wrong display.
enum WindowEnumerator {

    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.wallpaper",
        "com.apple.screencaptureui",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.universalcontrol",
        "com.apple.CoreLocationAgent"
    ]

    private static let excludedOwnerNames: Set<String> = [
        "Window Server", "WindowManager", "Dock", "SystemUIServer",
        "Control Centre", "Control Center", "Notification Centre", "Notification Center",
        "Spotlight", "Wallpaper", "AutoFill", "Open and Save Panel Service"
    ]

    struct Snapshot {
        var windows: [ManagedWindow] = []
        /// Every window the Accessibility API can still see, used to tell a window that is
        /// closing from one that is only minimising.
        var liveWindowIDs: Set<CGWindowID> = []
        /// Apps whose Accessibility window list was read successfully this pass.
        var probedPIDs: Set<pid_t> = []
    }

    static func snapshot(
        includeMinimized: Bool,
        previousOnScreenIDs: Set<CGWindowID> = [],
        scanMaxAge: TimeInterval = 2.0
    ) -> Snapshot {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // `NSRunningApplication(processIdentifier:)` searches the running-application list on
        // every call, and the raw window list runs to hundreds of entries — most of them
        // belonging to the same handful of processes. One lookup per process per pass.
        var apps: [pid_t: NSRunningApplication?] = [:]

        // Which window is *focused* is an Accessibility question. The front app's topmost
        // window in z-order is usually the same thing, but not always — a panel, or a window
        // on another display, can sit in front of the one actually taking keystrokes.
        let focusedID = frontPID.flatMap { AXWindowID.focusedWindow(pid: $0) }
        var seenFrontWindow = false
        var results: [ManagedWindow] = []
        var claimed = Set<CGWindowID>()

        // Every full-screen Space, whether it is the one on screen or not. A Space holds the
        // window plus the app's own full-screen toolbar, and the window server goes on calling
        // both "on screen" long after the user has swiped away — so without this the toolbar
        // arrived here as a second card for the same app, a sliver a fraction of the height of
        // a real preview.
        let spaces = includeMinimized ? SpaceInspector.spaces() : []
        let fullScreenSpaces = spaces.filter(\.isFullScreen)
        var spaceOfWindow: [CGWindowID: Int] = [:]
        for (index, space) in fullScreenSpaces.enumerated() {
            for id in space.windows { spaceOfWindow[id] = index }
        }
        var surfacesBySpace: [Int: [[String: Any]]] = [:]

        for (index, entry) in entries(options: [.optionOnScreenOnly, .excludeDesktopElements]).enumerated() {
            if let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
               let space = spaceOfWindow[id] {
                surfacesBySpace[space, default: []].append(entry)
            }
            guard var window = makeWindow(from: entry, isMinimized: false, apps: &apps) else { continue }
            // The on-screen list arrives front-to-back, which is the only place this
            // ordering is available; it is what tells each display which window is on top.
            window.zIndex = index
            if let focusedID {
                if window.id == focusedID {
                    window = window.markingActive()
                    seenFrontWindow = true
                }
            } else if !seenFrontWindow, let frontPID, window.pid == frontPID {
                // No Accessibility answer available: fall back to the front app's top window.
                window = window.markingActive()
                seenFrontWindow = true
            }
            results.append(window)
        }

        // Menus, popovers and Chromium's address-bar suggestion list are windows as far as
        // CoreGraphics is concerned, and would otherwise show up as duplicates of the window
        // they belong to.
        results = WindowSubroles.filtering(results)

        // A full-screen Space contains exactly one window. Anything else the app keeps there
        // is chrome, so only the winner survives.
        var fullScreenIDs = Set<CGWindowID>()
        for (space, surfaces) in surfacesBySpace {
            let winner = fullScreenWindow(among: surfaces).flatMap {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            }
            if let winner { fullScreenIDs.insert(winner) }
            let others = Set(fullScreenSpaces[space].windows).subtracting(winner.map { [$0] } ?? [])
            results.removeAll { others.contains($0.id) }
        }
        results = results.map { fullScreenIDs.contains($0.id) ? $0.markingFullScreen() : $0 }

        claimed = Set(results.map(\.id))

        guard includeMinimized else { return Snapshot(windows: results) }

        // A full-screen window occupies a Space of its own. Swipe back to the desktop and it
        // leaves the on-screen list entirely — so without this it had no card, and the one
        // window the user most needs a way back to was the one the dock could not offer.
        let hiddenSpaces = fullScreenSpaces.filter(\.isHidden)
        let offScreenFullScreen = hiddenSpaces.reduce(into: Set<CGWindowID>()) {
            $0.formUnion($1.windows)
        }.subtracting(claimed)

        // Going full screen takes the whole display, so every other window on it leaves the
        // on-screen list at once and the strip was left offering the one window the user is
        // already looking at. The desktop those windows are waiting on is the thing they want
        // a way back to, so it is enumerated too — but only for a display that is actually
        // showing a full-screen Space, since on an ordinary desktop the Spaces the user has
        // swiped away from are meant to stay out of the way.
        let fullScreenDisplays = Set(
            spaces.filter { $0.isFullScreen && !$0.isHidden }.map(\.display)
        )
        let offScreenDesktop = spaces.filter {
            $0.isHidden && !$0.isFullScreen && fullScreenDisplays.contains($0.display)
        }.reduce(into: Set<CGWindowID>()) {
            $0.formUnion($1.windows)
        }.subtracting(claimed).subtracting(offScreenFullScreen)

        let offScreen = offScreenFullScreen.union(offScreenDesktop)

        // A window that just left the on-screen list is either minimised, closed, or on
        // another Space. The cached Accessibility answer may predate that change, and
        // trusting it would drop the window from the strip for a moment before it came
        // back as minimised. Re-scan now so the handoff is seamless.
        //
        // Windows on a hidden full-screen Space are excluded: they are off screen for as long
        // as the user stays away, and counting them here asked for a fresh Accessibility
        // sweep — the most expensive thing this loop does — on every single tick.
        let vanished = previousOnScreenIDs.subtracting(claimed).subtracting(offScreen)
        if !vanished.isEmpty {
            DebugLog.log("snapshot: left screen \(vanished.sorted()) -> re-scanning AX")
            MinimizedScanner.invalidate()
        }

        let scan = MinimizedScanner.scan(maxAge: scanMaxAge)
        let minimizedIDs = scan.minimized
        guard !minimizedIDs.isEmpty || !offScreen.isEmpty else {
            return Snapshot(windows: results, liveWindowIDs: scan.existing, probedPIDs: scan.probedPIDs)
        }

        var minimized: [ManagedWindow] = []
        var candidates: [CGWindowID: [String: Any]] = [:]
        for entry in entries(options: [.optionAll, .excludeDesktopElements]) {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  !claimed.contains(id)
            else { continue }
            if minimizedIDs.contains(id) {
                guard let window = makeWindow(from: entry, isMinimized: true, apps: &apps) else { continue }
                claimed.insert(id)
                minimized.append(window)
            } else if offScreen.contains(id) {
                candidates[id] = entry
            }
        }

        results.append(contentsOf: collapsingTabs(minimized))

        var offScreenIDs = Set<CGWindowID>()
        for space in hiddenSpaces {
            guard let entry = fullScreenWindow(among: space.windows.compactMap { candidates[$0] }),
                  let window = makeWindow(from: entry, isMinimized: false, apps: &apps),
                  !claimed.contains(window.id)
            else { continue }
            claimed.insert(window.id)
            offScreenIDs.insert(window.id)
            results.append(window.markingFullScreen())
        }

        // A hidden desktop Space needs no such picking: it holds whatever the user left there,
        // and the ordinary rules — layer, opacity, size, an app that appears in the Dock —
        // already separate the windows from the widgets, menu bar and helper surfaces that
        // share the Space with them. Subroles are deliberately not consulted: the apps cannot
        // answer while their Space is away, so asking would cost an Accessibility sweep per
        // tick and learn nothing.
        var hidden: [ManagedWindow] = []
        for id in offScreenDesktop.sorted() {
            guard let entry = candidates[id], !claimed.contains(id),
                  let window = makeWindow(from: entry, isMinimized: false, apps: &apps)
            else { continue }
            claimed.insert(id)
            hidden.append(window)
        }
        let hiddenKept = collapsingTabs(hidden)
        offScreenIDs.formUnion(hiddenKept.map(\.id))
        results.append(contentsOf: hiddenKept)

        // An app whose Space is hidden answers the Accessibility sweep with no windows at all,
        // which the store would otherwise read as "they were all closed" and drop the cards a
        // beat after adding them. The window server has just said these windows exist, and it
        // is the authority, so they count as live.
        //
        // Only the windows, not every surface that shares their Space: counting the rest kept
        // the app's full-screen toolbar — a card of its own for as long as its Space was on
        // screen — alive for ever afterwards, as a sliver that could never be closed.
        return Snapshot(
            windows: results,
            liveWindowIDs: scan.existing.union(offScreenIDs),
            probedPIDs: scan.probedPIDs
        )
    }

    // MARK: - Helpers

    /// The on-screen frame of each of the given windows, as CoreGraphics reports it right now.
    ///
    /// Deliberately cheap — a single window-list read, no Accessibility probing — because it
    /// runs either side of a capture pass to check the subject held still.
    ///
    /// Asks the window server about only the requested IDs rather than copying the whole
    /// on-screen list and filtering it down: this runs twice around every capture pass, on
    /// the main actor, and the on-screen list can run to hundreds of entries. Off-screen
    /// windows are still dropped, so a window that minimised or closed mid-pass reports no
    /// frame exactly as before — which is what the capture code reads as "it moved, discard".
    static func frames(for ids: Set<CGWindowID>) -> [CGWindowID: CGRect] {
        guard !ids.isEmpty else { return [:] }
        // `CGWindowListCreateDescriptionFromArray` takes a CFArray whose elements are the
        // window IDs themselves encoded as pointer values — not CFNumbers — backed by a
        // null-callback array so it never tries to retain them as objects.
        let idArray = Array(ids)
        let pointers = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: idArray.count)
        defer { pointers.deallocate() }
        for (index, id) in idArray.enumerated() {
            pointers[index] = UnsafeRawPointer(bitPattern: UInt(id))
        }
        guard let cfArray = CFArrayCreate(kCFAllocatorDefault, pointers, idArray.count, nil),
              let raw = CGWindowListCreateDescriptionFromArray(cfArray) as? [[String: Any]]
        else { return [:] }

        var frames: [CGWindowID: CGRect] = [:]
        for entry in raw {
            // `CGWindowListCreateDescriptionFromArray` ignores the on-screen filter, so it
            // has to be applied by hand to match the old `.optionOnScreenOnly` behaviour.
            guard (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            frames[id] = frame
        }
        return frames
    }

    private static func entries(options: CGWindowListOption) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// Picks the one real window out of the surfaces that share a full-screen Space.
    ///
    /// Measured, a full-screen Space holds the window itself plus the Dock's wallpaper and
    /// backdrop, the window server's menu bar, and the app's own full-screen toolbar. The
    /// wallpaper and backdrop are *larger* than the window and carry titles of their own, so
    /// layer and alpha are tested here rather than left to the caller's list options — the
    /// rule has to hold on its own or it silently picks the wallpaper and yields no card at
    /// all. That leaves the toolbar, a layer-0, fully opaque, app-owned surface exactly as the
    /// window is, which was showing up as a second sliver-shaped card; what separates them is
    /// that the toolbar has no title and the window does. A Space has exactly one full-screen
    /// window, so picking a single winner is not a heuristic but the definition.
    static func fullScreenWindow(among entries: [[String: Any]]) -> [String: Any]? {
        entries.filter { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { return false }
            return !(((entry[kCGWindowName as String] as? String) ?? "").isEmpty)
        }.max { first, second in
            area(of: first) < area(of: second)
        }
    }

    static func area(of entry: [String: Any]) -> CGFloat {
        guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return 0 }
        return frame.width * frame.height
    }

    /// Collapses the extra windows a tabbed window turns into while it is off screen.
    ///
    /// Measured: a Terminal window with two tabs is one window in the Accessibility list and
    /// two in the CoreGraphics one — each tab has its own window ID, and only the active tab
    /// is on screen. Minimise it and the app suddenly reports *every* tab as a minimised
    /// window, all at the same frame and title, so the strip grew a card per tab for what the
    /// user minimised as one window. Restore it and they collapse back into one again.
    ///
    /// Windows of one app sharing an exact frame while off screen are therefore treated as
    /// tabs of a single window, and only the frontmost is kept — the one the app brings back.
    /// On-screen windows are deliberately not collapsed: only the active tab is ever on
    /// screen, and two ordinary windows can legitimately sit exactly on top of each other.
    static func collapsingTabs(_ windows: [ManagedWindow]) -> [ManagedWindow] {
        struct Key: Hashable {
            let pid: pid_t
            let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
        }
        var seen = Set<Key>()
        return windows.filter { window in
            let key = Key(pid: window.pid, x: window.frame.origin.x, y: window.frame.origin.y,
                          width: window.frame.width, height: window.frame.height)
            return seen.insert(key).inserted
        }
    }

    private static func makeWindow(
        from entry: [String: Any],
        isMinimized: Bool,
        apps: inout [pid_t: NSRunningApplication?]
    ) -> ManagedWindow? {
        guard
            let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
            let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let pidNumber = entry[kCGWindowOwnerPID as String] as? NSNumber
        else { return nil }

        let pid = pid_t(pidNumber.int32Value)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        guard alpha > 0.05 else { return nil }

        guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              frame.width >= 120, frame.height >= 80
        else { return nil }

        // Only apps that appear in the Dock own windows a user would want to switch between.
        let cached = apps[pid] ?? {
            let looked = NSRunningApplication(processIdentifier: pid)
            apps[pid] = looked
            return looked
        }()
        guard let app = cached, app.activationPolicy == .regular else { return nil }

        if let bundleID = app.bundleIdentifier, excludedBundleIDs.contains(bundleID) { return nil }

        let ownerName = (entry[kCGWindowOwnerName as String] as? String) ?? app.localizedName ?? "Unknown"
        if excludedOwnerNames.contains(ownerName) { return nil }

        return ManagedWindow(
            id: windowID,
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            appName: ownerName,
            title: (entry[kCGWindowName as String] as? String) ?? "",
            frame: frame,
            isActive: false,
            isMinimized: isMinimized
        )
    }
}
