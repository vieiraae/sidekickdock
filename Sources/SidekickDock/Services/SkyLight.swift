import AppKit

/// Focuses a specific window without activating its application.
///
/// `NSRunningApplication.activate` and the Accessibility `AXFrontmost` attribute are both
/// application-level operations, and macOS responds to them by raising that app's frontmost
/// window on *every* display it occupies. For a dock whose entire purpose is additive
/// activation that is unacceptable: clicking a card on one screen would shove an unrelated
/// window to the front of another. Correcting it afterwards is always visible, because the
/// window server has already drawn the wrong frame by the time it can be measured.
///
/// The window server itself does support per-window focus, and this is the interface the
/// Dock and Mission Control use for it. It is private, so every symbol is resolved at run
/// time and the caller is expected to fall back to public API when unavailable.
enum SkyLight {

    private typealias SetFrontProcessFn = @convention(c) (
        UnsafePointer<ProcessSerialNumber>, UInt32, UInt32
    ) -> Int32
    private typealias PostEventFn = @convention(c) (
        UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>
    ) -> Int32
    private typealias GetProcessForPIDFn = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> Int32

    /// Treat the focus request as user-initiated, exactly as a click would be.
    private static let userGenerated: UInt32 = 0x200
    /// Bring the process forward without bringing any of its windows with it. Without this
    /// Measured to make no difference to whether an app raises its other windows, despite the
    /// name, so it is not used. Recorded here only so the experiment is not repeated.
    private static let noWindows: UInt32 = 0x400

    private static var options: UInt32 { userGenerated }


    private static let skyLight: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        RTLD_LAZY
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let address = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    private static let setFrontProcess = symbol(
        "SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self
    )
    private static let postEvent = symbol("SLPSPostEventRecordTo", as: PostEventFn.self)
    private static let getProcessForPID: GetProcessForPIDFn? = {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }
        return unsafeBitCast(address, to: GetProcessForPIDFn.self)
    }()

    static var isAvailable: Bool {
        setFrontProcess != nil && postEvent != nil && getProcessForPID != nil
    }

    /// Gives keyboard focus to one window, leaving the z-order of every other window —
    /// including this app's own windows on other displays — untouched.
    static func focusWithoutRaising(
        pid: pid_t,
        windowID: CGWindowID,
        replacing previous: CGWindowID?
    ) -> Bool {
        guard let setFrontProcess, let getProcessForPID else { return false }

        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == 0 else {
            DebugLog.log("SkyLight: no process serial number for pid \(pid)")
            return false
        }

        // Switching between two windows of the app that is *already* frontmost is the
        // awkward case: there is no process switch for the window server to hang the focus
        // change on, so the app runs its own activation path instead — and apps like Outlook
        // respond to that by re-ordering their windows, raising a sibling on another
        // display. Naming the outgoing and incoming windows explicitly keeps the change
        // inside the window server, where it belongs.
        let alreadyFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        DebugLog.log("focus #\(windowID) pid=\(pid) previous=\(previous.map(String.init) ?? "-") alreadyFront=\(alreadyFront)")
        if alreadyFront, let previous, previous != windowID {
            DebugLog.log("SkyLight: same-app focus #\(previous) -> #\(windowID)")
            postWindowFocusChange(psn: &psn, from: previous, to: windowID)
        }

        // Order matters, and this order is load-bearing: an app raises whichever window it
        // believes is focused at the moment it is activated, so it must be told about the
        // new key window *before* the process switch. With the two swapped, activating an
        // app from another display reliably raises a stale sibling window on this one.
        makeKeyWindow(psn: &psn, windowID: windowID)

        // Only when the app is not already frontmost. Asking the window server to front an
        // app that is *already* fronted still runs that app's activation path, and apps
        // respond by raising their own windows on other displays. The key-window events
        // above are enough on their own to raise and focus a window within the active app.
        if !alreadyFront {
            guard setFrontProcess(&psn, windowID, options) == 0 else {
                DebugLog.log("SkyLight: SLPSSetFrontProcessWithOptions failed for #\(windowID)")
                return false
            }

            // And again afterwards. The events above are addressed to a process that was not
            // yet frontmost, and the window server discards them in that state, while the
            // process switch fronts the app without reordering its windows — so the clicked
            // window stayed behind another app's, and only a second click (by which point
            // the app *was* frontmost) appeared to work. Repeating them once the app is
            // forward is what actually raises the window.
            makeKeyWindow(psn: &psn, windowID: windowID)
        }

        return true
    }

    /// Tells the app to treat one of its windows as deactivated and another as activated,
    /// without going through its own window management.
    private static func postWindowFocusChange(
        psn: inout ProcessSerialNumber,
        from previous: CGWindowID,
        to next: CGWindowID
    ) {
        guard let postEvent else { return }

        var deactivate = eventRecord(marker: 0x0d, windowID: previous)
        deactivate[0x8a] = 0x02
        _ = postEvent(&psn, deactivate)

        // The app needs a moment to process the first event before the second arrives.
        usleep(1000)

        var activate = eventRecord(marker: 0x0d, windowID: next)
        activate[0x8a] = 0x01
        _ = postEvent(&psn, activate)
    }

    private static func eventRecord(marker: UInt8, windowID: CGWindowID) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = marker
        withUnsafeBytes(of: windowID.littleEndian) { raw in
            for (offset, byte) in raw.enumerated() { bytes[0x3c + offset] = byte }
        }
        return bytes
    }

    /// Setting the front process points the app at the window, but the app itself only
    /// treats it as key once it receives the pair of window-activation events the window
    /// server would normally send on a click.
    private static func makeKeyWindow(psn: inout ProcessSerialNumber, windowID: CGWindowID) {
        guard let postEvent else { return }

        for marker: UInt8 in [0x01, 0x02] {
            var bytes = eventRecord(marker: marker, windowID: windowID)
            bytes[0x3a] = 0x10
            for index in 0x20..<0x30 { bytes[index] = 0xff }
            _ = postEvent(&psn, bytes)
        }
    }
}
