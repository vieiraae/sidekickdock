import AppKit
import Combine

/// Owns one dock panel per display and drives the edge-hover reveal choreography.
@MainActor
final class DockManager {
    static let shared = DockManager()

    private var controllers: [CGDirectDisplayID: DockController] = [:]
    private var monitors: [Any] = []
    private var pointerPoll: Timer?
    private var revealWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    private var revealedDisplay: CGDirectDisplayID?
    private var cancellables = Set<AnyCancellable>()
    private var isRunning = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        rebuildPanels()
        installPointerMonitors()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in self.rebuildPanels() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                self.hideAll()
                WindowStore.shared.refreshNow()
            }
        }

        Preferences.shared.$edge
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.updateFrames() } }
            .store(in: &cancellables)

        Preferences.shared.$cardWidth
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.updateFrames() } }
            .store(in: &cancellables)

        WindowStore.shared.$windows
            .sink { [weak self] _ in Task { @MainActor in self?.syncPanelVisibility() } }
            .store(in: &cancellables)

        WindowStore.shared.$fullScreenDisplays
            .sink { [weak self] _ in Task { @MainActor in self?.syncPanelVisibility() } }
            .store(in: &cancellables)

        WindowStore.shared.start()
        SwitcherHotKey.start()
    }

    func stop() {
        isRunning = false
        pointerPoll?.invalidate()
        pointerPoll = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        SwitcherHotKey.stop()
        controllers.values.forEach { $0.tearDown() }
        controllers.removeAll()
        WindowStore.shared.stop()
    }

    // MARK: - Panels

    private func rebuildPanels() {
        var live = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let id = ScreenGeometry.displayID(of: screen)
            live.insert(id)
            if let existing = controllers[id] {
                existing.updateFrame(for: screen)
            } else {
                controllers[id] = DockController(screen: screen)
            }
        }
        for (id, controller) in controllers where !live.contains(id) {
            controller.tearDown()
            controllers.removeValue(forKey: id)
        }
        if let revealedDisplay, !live.contains(revealedDisplay) {
            self.revealedDisplay = nil
        }
        syncPanelVisibility()
    }

    private func updateFrames() {
        for screen in NSScreen.screens {
            controllers[ScreenGeometry.displayID(of: screen)]?.updateFrame(for: screen)
        }
    }

    private func syncPanelVisibility() {
        let store = WindowStore.shared
        for (id, controller) in controllers {
            let empty = store.windows(on: id).isEmpty
            controller.setEmpty(empty)
            // A screen-filling active window only hides the resting sliver; the edge
            // trigger still works, so the dock stays reachable.
            controller.setHidesPeek(store.fullScreenDisplays.contains(id))
            if empty, revealedDisplay == id {
                controller.setRevealed(false)
                revealedDisplay = nil
                cancelReveal()
            }
        }
    }

    // MARK: - Pointer

    private func installPointerMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            Task { @MainActor in DockManager.shared.pointerMoved(to: NSEvent.mouseLocation) }
        }) {
            monitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            Task { @MainActor in DockManager.shared.pointerMoved(to: NSEvent.mouseLocation) }
            return event
        }) {
            monitors.append(local)
        }

        // The panel is hit-testable even while collapsed, and macOS does not deliver
        // mouse-moved events to an inactive accessory app's own windows. Without this poll
        // the pointer could sit on the collapsed strip and never trigger the reveal.
        let poll = Timer(timeInterval: 0.06, repeats: true) { _ in
            Task { @MainActor in DockManager.shared.pointerMoved(to: NSEvent.mouseLocation) }
        }
        poll.tolerance = 0.02
        RunLoop.main.add(poll, forMode: .common)
        pointerPoll = poll
    }

    private func pointerMoved(to point: NSPoint) {
        guard Permissions.shared.allGranted else { return }

        // Panels only take the clicks that land on a card; everything else goes through to
        // the desktop or the window behind.
        for controller in controllers.values {
            controller.updateClickThrough(pointer: point)
        }

        if let revealedDisplay, let controller = controllers[revealedDisplay] {
            if controller.hoverFrame.contains(point) {
                cancelHide()
                cancelReveal()
                return
            }
            scheduleHide()
        }

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        let id = ScreenGeometry.displayID(of: screen)
        guard let controller = controllers[id] else { return }

        if controller.triggerZone(for: screen).contains(point) {
            guard revealedDisplay != id, !controller.isSuppressed else { return }
            scheduleReveal(for: id)
        } else if revealedDisplay == nil {
            cancelReveal()
        }
    }

    private func scheduleReveal(for id: CGDirectDisplayID) {
        guard revealWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.revealWorkItem = nil
                self?.reveal(id)
            }
        }
        revealWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Preferences.shared.revealDelay, execute: item)
    }

    private func cancelReveal() {
        revealWorkItem?.cancel()
        revealWorkItem = nil
    }

    private func scheduleHide() {
        guard hideWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.hideWorkItem = nil
                self?.hideAll()
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    // MARK: - Reveal

    func reveal(_ id: CGDirectDisplayID) {
        cancelHide()
        guard controllers[id]?.isSuppressed == false else { return }
        for (displayID, controller) in controllers {
            controller.setRevealed(displayID == id)
        }
        revealedDisplay = id
    }

    /// Menu-bar action: reveal on whichever display currently has the pointer.
    func revealUnderPointer() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return }
        reveal(ScreenGeometry.displayID(of: screen))
    }

    func hideAll() {
        cancelReveal()
        cancelHide()
        controllers.values.forEach { $0.setRevealed(false) }
        revealedDisplay = nil
    }
}
