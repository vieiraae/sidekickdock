import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(
            rootView: SettingsView()
                .environmentObject(Preferences.shared)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "SidekickDock Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        Permissions.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class StatusItemController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init() {
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.stack",
                accessibilityDescription: "SidekickDock"
            )
            button.image?.isTemplate = true
            button.toolTip = "SidekickDock"
        }
        item.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let reveal = NSMenuItem(title: "Reveal Dock", action: #selector(revealDock), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let refresh = NSMenuItem(title: "Refresh Previews", action: #selector(refreshPreviews), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SidekickDock", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func revealDock() { DockManager.shared.revealUnderPointer() }
    @objc private func refreshPreviews() { WindowStore.shared.refreshNow() }
    @objc private func openSettings() { SettingsWindowController.shared.present() }
    @objc private func quit() { NSApp.terminate(nil) }
}
