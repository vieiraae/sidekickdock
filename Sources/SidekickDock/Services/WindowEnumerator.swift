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

        for (index, entry) in entries(options: [.optionOnScreenOnly, .excludeDesktopElements]).enumerated() {
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
        claimed = Set(results.map(\.id))

        guard includeMinimized else { return Snapshot(windows: results) }

        // A window that just left the on-screen list is either minimised, closed, or on
        // another Space. The cached Accessibility answer may predate that change, and
        // trusting it would drop the window from the strip for a moment before it came
        // back as minimised. Re-scan now so the handoff is seamless.
        if !previousOnScreenIDs.subtracting(claimed).isEmpty {
            DebugLog.log("snapshot: left screen \(previousOnScreenIDs.subtracting(claimed).sorted()) -> re-scanning AX")
            MinimizedScanner.invalidate()
        }

        let scan = MinimizedScanner.scan(maxAge: scanMaxAge)
        let minimizedIDs = scan.minimized
        guard !minimizedIDs.isEmpty else {
            return Snapshot(windows: results, liveWindowIDs: scan.existing, probedPIDs: scan.probedPIDs)
        }

        for entry in entries(options: [.optionAll, .excludeDesktopElements]) {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  minimizedIDs.contains(id),
                  !claimed.contains(id)
            else { continue }
            guard let window = makeWindow(from: entry, isMinimized: true, apps: &apps) else { continue }
            claimed.insert(id)
            results.append(window)
        }

        return Snapshot(windows: results, liveWindowIDs: scan.existing, probedPIDs: scan.probedPIDs)
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
