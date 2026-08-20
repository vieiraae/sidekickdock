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

    /// Space types as reported by the window server: 0 user, 2 system, 4 full screen.
    private static let fullScreenSpace = 4

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
