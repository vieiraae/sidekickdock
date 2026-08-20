import ApplicationServices
import CoreGraphics

/// Maps Accessibility elements onto CoreGraphics window IDs.
///
/// `_AXUIElementGetWindow` is the only reliable bridge between the two window worlds this app
/// lives in: the Accessibility API knows about focus and minimisation, CoreGraphics knows
/// about z-order and previews, and nothing public joins them. It is resolved dynamically, so
/// a release that removes it degrades to heuristic matching instead of failing to launch.
enum AXWindowID {

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindowFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFn.self)
    }()

    static var isAvailable: Bool { getWindow != nil }

    static func of(_ element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var identifier: CGWindowID = 0
        guard getWindow(element, &identifier) == .success, identifier != 0 else { return nil }
        return identifier
    }

    /// The window an application currently considers focused.
    static func focusedWindow(pid: pid_t) -> CGWindowID? {
        guard isAvailable else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // Never let an unresponsive app stall the caller.
        AXUIElementSetMessagingTimeout(app, 0.25)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return of(value as! AXUIElement)
    }
}
