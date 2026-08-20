import AppKit
import CoreGraphics

/// A single on-screen window represented as a card in the dock.
struct ManagedWindow: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String
    let title: String
    /// Window frame in CoreGraphics global space (origin at top-left of the main display).
    let frame: CGRect
    let isActive: Bool
    let isMinimized: Bool
    /// Position in the window server's front-to-back ordering, lowest is frontmost. Windows
    /// that are not on screen have no meaningful position and sort last.
    var zIndex: Int = .max

    var displayTitle: String { title.isEmpty ? appName : title }

    var aspectRatio: CGFloat {
        guard frame.height > 1 else { return 16.0 / 10.0 }
        return max(0.35, min(3.2, frame.width / frame.height))
    }

    @MainActor var appIcon: NSImage? { AppIconCache.icon(for: pid) }

    static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isActive == rhs.isActive
            && lhs.isMinimized == rhs.isMinimized
            && lhs.frame == rhs.frame
    }

    func markingActive() -> ManagedWindow {
        ManagedWindow(
            id: id,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            title: title,
            frame: frame,
            isActive: true,
            isMinimized: isMinimized,
            zIndex: zIndex
        )
    }

    func markingMinimized() -> ManagedWindow {
        ManagedWindow(
            id: id,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            title: title,
            frame: frame,
            isActive: false,
            isMinimized: true,
            zIndex: zIndex
        )
    }

    /// Substitutes a known-good frame for one that cannot be trusted yet.
    func withFrame(_ replacement: CGRect) -> ManagedWindow {
        ManagedWindow(
            id: id,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            title: title,
            frame: replacement,
            isActive: isActive,
            isMinimized: isMinimized,
            zIndex: zIndex
        )
    }

    func markingRestored() -> ManagedWindow {
        ManagedWindow(
            id: id,
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            title: title,
            frame: frame,
            isActive: isActive,
            isMinimized: false,
            zIndex: zIndex
        )
    }
}

/// Application icons, kept per process.
///
/// `appIcon` is read from a SwiftUI body, so it runs on every render of every card in every
/// strip and every switcher tile. `NSRunningApplication(processIdentifier:)` walks the
/// running-application list on each call, which is far too much work for a redraw.
@MainActor
enum AppIconCache {
    private static var icons: [pid_t: NSImage] = [:]

    static func icon(for pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon else { return nil }
        icons[pid] = icon
        // Bounded by the number of running applications, and a terminated process's entry is
        // just a stale image until then, so a periodic sweep is enough.
        if icons.count > 64 { prune() }
        return icon
    }

    private static func prune() {
        let live = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        icons = icons.filter { live.contains($0.key) }
    }
}

enum ScreenGeometry {
    /// Height of the whole desktop in AppKit coordinates, used to flip between AppKit and CG space.
    static var globalHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 0
    }

    /// Converts an AppKit (bottom-left origin) rect into CoreGraphics (top-left origin) space.
    static func flip(_ frame: CGRect, globalHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: globalHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    /// Converts an AppKit (bottom-left origin) rect into CoreGraphics (top-left origin) space.
    static func cgFrame(of screen: NSScreen) -> CGRect {
        flip(screen.frame, globalHeight: globalHeight)
    }

    /// The usable area of a display — excluding the menu bar and Dock — in CoreGraphics space.
    static func cgVisibleFrame(of screen: NSScreen) -> CGRect {
        flip(screen.visibleFrame, globalHeight: globalHeight)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func screen(for identifier: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == identifier }
    }

    /// Picks the display that holds the largest slice of the window.
    static func owningDisplay(for frame: CGRect) -> CGDirectDisplayID? {
        owningDisplay(for: frame, among: NSScreen.screens.map { (displayID(of: $0), cgFrame(of: $0)) })
    }

    /// The display choice on its own, in CoreGraphics space, so it can be exercised without
    /// a real screen arrangement.
    static func owningDisplay(
        for frame: CGRect,
        among displays: [(id: CGDirectDisplayID, frame: CGRect)]
    ) -> CGDirectDisplayID? {
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for display in displays {
            let overlap = display.frame.intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            guard area > 0 else { continue }
            if best == nil || area > best!.area {
                best = (display.id, area)
            }
        }
        if let best { return best.id }

        // Fully off-screen, or degenerate: fall back to the nearest display rather than
        // whichever display happens to have focus, so a window never jumps to the wrong strip.
        // Distance is measured to the display's edges, not its centre — a zero-sized window
        // sitting inside a large display is nearest to *that* display, however far its middle
        // happens to be.
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var nearest: (id: CGDirectDisplayID, distance: CGFloat)?
        for display in displays {
            let dx = max(display.frame.minX - center.x, 0, center.x - display.frame.maxX)
            let dy = max(display.frame.minY - center.y, 0, center.y - display.frame.maxY)
            let distance = hypot(dx, dy)
            if nearest == nil || distance < nearest!.distance {
                nearest = (display.id, distance)
            }
        }
        return nearest?.id
    }
}
