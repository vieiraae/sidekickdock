import AppKit
import CoreGraphics

/// Intercepts ⌘Tab so the dock's own switcher stands in for the system application switcher.
///
/// A `CGEventTap` is the only way to take ⌘Tab: it is a reserved system shortcut, so it never
/// reaches an ordinary key monitor and cannot be claimed with `RegisterEventHotKey`. The tap
/// needs the Accessibility grant the dock already holds; if it cannot be created the system
/// switcher simply keeps working.
@MainActor
enum SwitcherHotKey {

    private enum Key {
        static let tab: Int64 = 48
        static let escape: Int64 = 53
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
    }

    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?

    static var isInstalled: Bool { tap != nil }

    static func start() {
        guard tap == nil else { return }

        let mask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: switcherTapCallback,
            userInfo: nil
        ) else {
            DebugLog.log("switcher: event tap could not be created (Accessibility?)")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        source = runLoopSource
        DebugLog.log("switcher: event tap installed")
    }

    static func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        SwitcherController.shared.cancel()
    }

    /// Re-arms after the system disables the tap, which it does if a callback ever runs long.
    static func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLog.log("switcher: event tap re-enabled")
    }

    /// Returns nil to swallow the event.
    static func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        let switcher = SwitcherController.shared
        guard Preferences.shared.replaceCommandTab else {
            // Turned off mid-cycle: without this the overlay would sit there forever, since
            // the Command release that commits it would no longer be read.
            switcher.cancel()
            return event
        }

        let flags = event.flags
        let command = flags.contains(.maskCommand)

        switch type {
        case .flagsChanged:
            // Releasing Command is what commits, exactly as the system switcher behaves.
            if !command, switcher.isEngaged { switcher.commit() }
            return event

        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return (code == Key.tab && switcher.isEngaged) ? nil : event

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)

            if command, code == Key.tab {
                switcher.step(by: flags.contains(.maskShift) ? -1 : 1)
                return nil
            }

            guard switcher.isEngaged else { return event }

            switch code {
            case Key.escape:
                switcher.cancel()
                return nil
            case Key.left, Key.up:
                switcher.stepSpatially(by: -1)
                return nil
            case Key.right, Key.down:
                switcher.stepSpatially(by: 1)
                return nil
            default:
                // Anything else while cycling is not ours; let it through untouched.
                return event
            }

        default:
            return event
        }
    }
}

/// Top-level so it carries no context, which a C callback cannot have.
private let switcherTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { SwitcherHotKey.reenable() }
        return Unmanaged.passUnretained(event)
    }

    // The tap is attached to the main run loop, so this callback is already on the main thread.
    let result = MainActor.assumeIsolated { SwitcherHotKey.handle(type: type, event: event) }
    return result.map { Unmanaged.passUnretained($0) }
}
