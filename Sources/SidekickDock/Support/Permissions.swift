import AppKit
import ApplicationServices
import CoreGraphics

/// Tracks the two TCC permissions the dock depends on:
/// Screen Recording (live window previews) and Accessibility (raising windows).
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var hasScreenRecording = false
    @Published private(set) var hasAccessibility = false

    var allGranted: Bool { hasScreenRecording && hasAccessibility }

    private var timer: Timer?

    private init() {
        refresh()
    }

    func refresh() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        hasAccessibility = AXIsProcessTrusted()
        if hasScreenRecording { screenRecordingNeedsManualAdd = false }
    }

    /// Set once a Screen Recording request has come back without a grant. macOS is then
    /// supposed to have listed us under Screen & System Audio Recording, but that
    /// registration is not reliable: observed on macOS 26 with a Developer ID build that was
    /// registered with LaunchServices, `CGRequestScreenCaptureAccess()` returned false,
    /// showed no prompt, and added no row — leaving the user staring at a list we were not
    /// in. When that happens the only way through is to add the bundle by hand with the `+`
    /// button, so the UI surfaces that route rather than dead-ending.
    @Published private(set) var screenRecordingNeedsManualAdd = false

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            screenRecordingNeedsManualAdd = true
        }
        refresh()
    }

    /// Opens Finder with the bundle selected, so the `+` file picker lands on it in one drag
    /// or paste. `Bundle.main.bundleURL` is the running bundle, which is the one macOS wants
    /// listed — pointing at anything else would grant a copy that is not the app running.
    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func copyAppPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Bundle.main.bundleURL.path, forType: .string)
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        refresh()
    }

    /// Poll *while permissions are missing* so the UI unlocks the moment the user grants
    /// them, then stop: an accessory app that lives for days should not wake once a second
    /// forever to re-ask a question that has already been answered.
    func startWatching(onChange: @escaping (Bool) -> Void) {
        timer?.invalidate()
        timer = nil
        guard !allGranted else { return }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let was = self.allGranted
                self.refresh()
                guard was != self.allGranted else { return }
                onChange(self.allGranted)
                if self.allGranted { self.stopWatching() }
            }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
