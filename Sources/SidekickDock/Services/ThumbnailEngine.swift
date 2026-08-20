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
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
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
            if let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            ) {
                output[window.windowID] = image
            }
        }

        return output
    }
}
