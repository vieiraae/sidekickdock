import AppKit
import SwiftUI

/// The three controls a window carries in its own title bar, drawn over a preview.
///
/// Shared by the strip's cards and the switcher's tiles so the two can never drift apart in
/// order, colour or behaviour — they are meant to read as the window's own buttons, and a
/// second copy of that drawing code is exactly how that illusion gets broken.
struct WindowTrafficLights: View {
    enum Control: CaseIterable {
        case close, minimize, fullScreen

        var color: Color {
            switch self {
            case .close: return Color(red: 1, green: 0.37, blue: 0.34)
            case .minimize: return Color(red: 1, green: 0.74, blue: 0.18)
            case .fullScreen: return Color(red: 0.16, green: 0.78, blue: 0.25)
            }
        }

        /// The green button is the only one that changes meaning: on a full-screen window it
        /// leaves full screen, so its arrows point inwards, exactly as the window's own do.
        func symbol(isFullScreen: Bool) -> String {
            switch self {
            case .close: return "xmark"
            case .minimize: return "minus"
            case .fullScreen:
                return isFullScreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            }
        }

        func label(isFullScreen: Bool) -> String {
            switch self {
            case .close: return "Close"
            case .minimize: return "Minimise"
            case .fullScreen: return isFullScreen ? "Exit Full Screen" : "Full Screen"
            }
        }
    }

    let window: ManagedWindow
    var diameter: CGFloat = 13
    var spacing: CGFloat = 6
    /// Whether hovering the green button reveals the Move & Resize menu. The strip wants it;
    /// the switcher does not, because that overlay is a transient thing the user is holding a
    /// shortcut to keep open, and a second panel over it would be in the way.
    var showsTileMenu: Bool = true
    /// Called when the pointer enters any part of the cluster. The cluster sits inside its
    /// host, so its own hover must never read as leaving that host.
    var onHoverChange: (Bool) -> Void = { _ in }
    /// Called after the action has been asked for, so the host can update its own view of the
    /// window — a frozen snapshot in particular has no other way to learn what just happened.
    var onAction: (Control) -> Void = { _ in }

    @State private var tileMenuWork: DispatchWorkItem?

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(Control.allCases), id: \.self) { light($0) }
        }
        .onHover { if $0 { onHoverChange(true) } }
    }

    private func light(_ control: Control) -> some View {
        // A minimised window has nothing to minimise, and a full-screen one cannot be
        // minimised at all — its Space would have nothing left in it, which is why macOS dims
        // that button in full screen too. Dimmed rather than removed, both because it is what
        // the window itself does and because removing it would shuffle the other two.
        let disabled = control == .minimize && !window.canMinimize

        return Circle()
            .fill(disabled ? Color.white.opacity(0.22) : control.color)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle().strokeBorder(Color.black.opacity(0.22), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: control.symbol(isFullScreen: window.isFullScreen))
                    .font(.system(size: diameter * 0.54, weight: .black))
                    .foregroundStyle(Color.black.opacity(disabled ? 0 : 0.62))
            }
            .contentShape(Circle())
            .onHover { hovering in
                if hovering { onHoverChange(true) }
                guard showsTileMenu, control == .fullScreen else { return }
                if hovering {
                    // macOS waits before revealing its own Move & Resize menu; opening
                    // instantly would flash it every time the pointer crosses the button.
                    let location = NSEvent.mouseLocation
                    tileMenuWork?.cancel()
                    let work = DispatchWorkItem {
                        TileMenuController.shared.show(for: window, at: location)
                    }
                    tileMenuWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
                } else {
                    tileMenuWork?.cancel()
                    TileMenuController.shared.scheduleHide()
                }
            }
            .onTapGesture {
                let store = WindowStore.shared
                switch control {
                case .close: store.close(window)
                case .minimize: store.minimize(window)
                case .fullScreen:
                    tileMenuWork?.cancel()
                    TileMenuController.shared.close()
                    store.toggleFullScreen(window)
                }
                onAction(control)
            }
            .allowsHitTesting(!disabled)
            .help(control.label(isFullScreen: window.isFullScreen))
            .accessibilityLabel("\(control.label(isFullScreen: window.isFullScreen)) \(window.appName)")
    }
}
