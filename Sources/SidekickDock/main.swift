import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = StatusItemController()

        Permissions.shared.refresh()
        Permissions.shared.startWatching { granted in
            if granted { WindowStore.shared.refreshNow() }
        }

        if !Permissions.shared.allGranted {
            SettingsWindowController.shared.present()
        }

        DockManager.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DockManager.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindowController.shared.present()
        return true
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    // Keep the delegate alive for the process lifetime.
    objc_setAssociatedObject(application, "SidekickDockDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    application.run()
}
