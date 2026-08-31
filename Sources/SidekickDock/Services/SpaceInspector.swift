import AppKit

/// Reports which displays are currently showing a full-screen Space.
///
/// A full-screen window lives in a Space of its own, and the CoreGraphics window list only
/// ever describes the Space in front. The full-screen window is therefore absent from the
/// enumeration entirely, and the only windows still visible there are whatever else its app
/// keeps in that Space — which is why the strip appeared to filter itself down to one app.
/// There is nothing useful to show on such a display, so the dock stays out of the way, which
/// is also what Stage Manager does.
///
/// The Spaces API is private, so every symbol is resolved at run time and an empty result
/// simply means the old frame-based test is left to decide on its own.
enum SpaceInspector {

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowsForSpacesFn = @convention(c) (
        Int32, UInt32, CFArray, UInt32,
        UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?
    private typealias SetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void

    /// Space types as reported by the window server: 0 user, 2 system, 4 full screen.
    private static let fullScreenSpace = 4

    /// Asks for every window in a Space rather than only the ones the caller owns.
    private static let everyWindowInSpace: UInt32 = 0x2

    private static let skyLight: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        RTLD_LAZY
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let address = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    private static let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionIDFn.self)
    private static let copyManagedDisplaySpaces = symbol(
        "SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self
    )
    private static let copyWindowsForSpaces = symbol(
        "SLSCopyWindowsWithOptionsAndTags", as: CopyWindowsForSpacesFn.self
    )
    private static let setCurrentSpace = symbol(
        "SLSManagedDisplaySetCurrentSpace", as: SetCurrentSpaceFn.self
    )

    /// One Space of one display.
    struct Space {
        let display: String
        let identifier: UInt64
        /// Full-screen Spaces hold exactly one window; a desktop Space holds any number.
        let isFullScreen: Bool
        /// Whether the user has swiped away from it.
        let isHidden: Bool
        /// Every surface the Space holds. A full-screen Space carries the window itself plus
        /// the wallpaper, backdrop, menu bar and the app's full-screen toolbar; telling those
        /// apart is the caller's job.
        let windows: [CGWindowID]
    }

    /// Every full-screen Space, on screen or not.
    ///
    /// Accessibility is no help here: an app whose Space is hidden reports no windows at all,
    /// so the usual sweep cannot see a full-screen window the moment the user swipes away from
    /// it — which is exactly when they want a card for it. The window server still knows, and
    /// this is the only way to ask.
    static func fullScreenSpaces() -> [Space] {
        spaces().filter(\.isFullScreen)
    }

    /// Every Space of every display, with the windows the window server says each one holds.
    static func spaces() -> [Space] {
        guard let mainConnectionID, let copyManagedDisplaySpaces, let copyWindowsForSpaces,
              let raw = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue(),
              let entries = raw as? [[String: Any]]
        else { return [] }

        let connection = mainConnectionID()
        var result: [Space] = []
        for entry in entries {
            guard let display = entry["Display Identifier"] as? String else { continue }
            let showing = (entry["Current Space"] as? [String: Any])?["id64"] as? Int
            for space in (entry["Spaces"] as? [[String: Any]]) ?? [] {
                guard let type = space["type"] as? Int,
                      let identifier = space["id64"] as? Int
                else { continue }

                var setTags: UInt64 = 0
                var clearTags: UInt64 = 0
                guard let windows = copyWindowsForSpaces(
                    connection, 0, [identifier] as CFArray, everyWindowInSpace, &setTags, &clearTags
                )?.takeRetainedValue(), let numbers = windows as? [NSNumber] else { continue }
                result.append(Space(
                    display: display,
                    identifier: UInt64(identifier),
                    isFullScreen: type == fullScreenSpace,
                    isHidden: identifier != showing,
                    windows: numbers.map { CGWindowID($0.uint32Value) }
                ))
            }
        }
        return result
    }

    /// Brings the Space holding `windowID` to the front of its display, if it is not already
    /// the one on screen.
    ///
    /// A window on a Space the user has swiped away from cannot be raised at all: measured,
    /// its app reports no Accessibility windows while the Space is hidden, and focusing
    /// through the window server changes nothing anybody can see. Activating the app does not
    /// help either. The Space has to come forward first, and this is the same call the system
    /// makes when the user swipes between Spaces themselves.
    ///
    /// Returns whether a switch was actually asked for, so the caller knows to wait for
    /// Accessibility to catch up — measured at about 100ms — before asking again.
    @discardableResult
    static func reveal(windowID: CGWindowID) -> Bool {
        guard let mainConnectionID, let setCurrentSpace else { return false }
        for space in spaces() where space.windows.contains(windowID) {
            guard space.isHidden else { return false }
            setCurrentSpace(mainConnectionID(), space.display as CFString, space.identifier)
            return true
        }
        return false
    }

    static func fullScreenDisplays() -> Set<CGDirectDisplayID> {
        guard let mainConnectionID, let copyManagedDisplaySpaces,
              let raw = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue(),
              let entries = raw as? [[String: Any]]
        else { return [] }

        var result: Set<CGDirectDisplayID> = []
        for entry in entries {
            guard let current = entry["Current Space"] as? [String: Any],
                  let type = current["type"] as? Int, type == fullScreenSpace,
                  let identifier = entry["Display Identifier"] as? String,
                  let display = displayID(matching: identifier)
            else { continue }
            result.insert(display)
        }
        return result
    }

    /// Display identifiers come back as UUID strings, except for the main display which some
    /// releases report as "Main".
    private static func displayID(matching identifier: String) -> CGDirectDisplayID? {
        if identifier == "Main" { return CGMainDisplayID() }

        for screen in NSScreen.screens {
            let display = ScreenGeometry.displayID(of: screen)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
                  let string = CFUUIDCreateString(nil, uuid) as String?
            else { continue }
            if string == identifier { return display }
        }
        return nil
    }
}
