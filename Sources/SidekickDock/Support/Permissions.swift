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
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
        refresh()
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
