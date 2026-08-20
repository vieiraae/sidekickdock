import AppKit
import Combine
import ServiceManagement

/// Wraps `SMAppService.mainApp` so the dock can relaunch itself at login.
///
/// The enabled flag is always read back from the system, never mirrored into
/// `UserDefaults`: the user can disable the login item from System Settings >
/// General > Login Items, and a cached copy would then disagree with reality
/// while still showing a checked box.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    /// True when macOS will relaunch SidekickDock at login.
    @Published private(set) var isEnabled = false

    /// macOS parks the registration in System Settings instead of failing when
    /// the user has never approved this app; the toggle stays off until they do.
    @Published private(set) var needsApproval = false

    /// Surfaced in Settings rather than swallowed — a silent failure here looks
    /// identical to a toggle that simply does not work.
    @Published private(set) var lastError: String?

    private var service: SMAppService { .mainApp }

    private init() {
        refresh()
    }

    func refresh() {
        let status = service.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
