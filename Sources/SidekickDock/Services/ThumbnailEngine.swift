import AppKit
@preconcurrency import ScreenCaptureKit

/// Captures downscaled live previews of individual windows with ScreenCaptureKit.
/// Runs off the main actor and serialises work so a busy desktop can't flood the GPU.
actor ThumbnailEngine {

    private var cachedContent: SCShareableContent?
    private var cachedContentAt: Date = .distantPast
    private let contentTTL: TimeInterval = 0.8

    private func shareableContent() async throws -> SCShareableContent {
        if let cachedContent, Date().timeIntervalSince(cachedContentAt) < contentTTL {
            return cachedContent
        }
        let content = try await withDeadline(seconds: 3) {
            try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        }
        cachedContent = content
        cachedContentAt = Date()
        return content
    }

    /// Captures previews for the requested window IDs. Returns only the ones that succeeded.
    ///
    /// `scales` gives the backing scale of the display each window sits on. Capturing
    /// everything at 2x looks identical on a Retina screen and wastes four times the pixels
    /// on a 1x one — which is easy to miss, because the developer's own laptop display is
    /// usually the Retina one.
    func capture(
        windowIDs: [CGWindowID],
        targetWidth: CGFloat,
        scales: [CGWindowID: CGFloat]
    ) async -> [CGWindowID: CGImage] {
        guard !windowIDs.isEmpty else { return [:] }
        guard let content = try? await shareableContent() else { return [:] }

        let wanted = Set(windowIDs)
        let targets = content.windows.filter { wanted.contains($0.windowID) }
        var output: [CGWindowID: CGImage] = [:]

        for window in targets {
            guard window.frame.width > 1, window.frame.height > 1 else { continue }
            let scale = min(1.0, targetWidth / window.frame.width)
            let backing = scales[window.windowID] ?? 2
            // Both dimensions are lifted by the same factor when either falls under the
            // floor. Clamping them independently would hand back an image of a different
            // shape than the window, which the card then has to crop or stretch to fit.
            var pixelWidth = window.frame.width * scale * backing
            var pixelHeight = window.frame.height * scale * backing
            let floor: CGFloat = 64
            if let lift = [floor / pixelWidth, floor / pixelHeight].max(), lift > 1 {
                pixelWidth *= lift
                pixelHeight *= lift
            }

            let configuration = SCStreamConfiguration()
            configuration.width = Int(pixelWidth.rounded())
            configuration.height = Int(pixelHeight.rounded())
            configuration.showsCursor = false
            configuration.scalesToFit = true
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.backgroundColor = .clear
            configuration.captureResolution = .nominal

            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let image = try? await withDeadline(seconds: 2, operation: {
                try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
            }) {
                output[window.windowID] = image
            }
        }

        return output
    }
}

/// Runs `operation`, giving up once `seconds` have passed.
///
/// Every preview capture happens inside the single refresh loop that keeps the dock in step
/// with the desktop, and ScreenCaptureKit offers no timeout of its own. One call that never
/// returns — which is what a display change or a wake from sleep can provoke — would stall
/// that loop for good, leaving a strip full of cards for windows that closed days ago. A
/// missed preview is a stale thumbnail for one tick; a stalled loop is a dead dock.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw DeadlineExceeded() }
        return result
    }
}

struct DeadlineExceeded: Error {}
