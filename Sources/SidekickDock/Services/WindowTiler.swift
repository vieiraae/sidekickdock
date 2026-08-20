import AppKit

/// Moves and resizes a window into one of the standard tiles.
///
/// macOS shows its own Move & Resize menu when the pointer rests on a window's green button,
/// but that menu belongs to the window and cannot be summoned for a window the dock is only
/// previewing. These are the same arrangements, applied through Accessibility.
enum WindowTiler {

    enum Tile: String, CaseIterable, Identifiable {
        case fill
        case left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .fill: return "rectangle.fill"
            case .left: return "rectangle.lefthalf.filled"
            case .right: return "rectangle.righthalf.filled"
            case .top: return "rectangle.tophalf.filled"
            case .bottom: return "rectangle.bottomhalf.filled"
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return "rectangle.fill"
            }
        }

        var label: String {
            switch self {
            case .fill: return "Fill"
            case .left: return "Left"
            case .right: return "Right"
            case .top: return "Top"
            case .bottom: return "Bottom"
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            }
        }

        /// The tile in unit terms, origin top-left, which is how the frame is drawn and how
        /// CoreGraphics describes a screen.
        var unitRect: CGRect {
            switch self {
            case .fill: return CGRect(x: 0, y: 0, width: 1, height: 1)
            case .left: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
            case .right: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
            case .top: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
            case .bottom: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
            case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
            case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
            case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
            case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
            }
        }
    }

    /// An arrangement lays the window out together with its neighbours on the same display,
    /// the way the system's Fill & Arrange section does.
    enum Arrangement: String, CaseIterable, Identifiable {
        case fill
        case leftAndRight
        case leftAndQuarters
        case quarters

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fill: return "Fill"
            case .leftAndRight: return "Left & Right"
            case .leftAndQuarters: return "Left & Quarters"
            case .quarters: return "Quarters"
            }
        }

        /// The panes in unit terms, origin top-left. The first pane belongs to the window the
        /// menu was opened for; the rest are filled by its neighbours, front to back.
        var panes: [CGRect] {
            switch self {
            case .fill:
                return [CGRect(x: 0, y: 0, width: 1, height: 1)]
            case .leftAndRight:
                return [
                    CGRect(x: 0, y: 0, width: 0.5, height: 1),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
                ]
            case .leftAndQuarters:
                return [
                    CGRect(x: 0, y: 0, width: 0.5, height: 1),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
                ]
            case .quarters:
                return [
                    CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                    CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                    CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
                ]
            }
        }
    }

    /// Applies `tile` on the display the window currently occupies.
    static func apply(_ tile: Tile, to window: ManagedWindow) {
        place(window, in: tile.unitRect)
    }

    /// Lays `window` out in the arrangement's first pane and fills the remaining panes with
    /// the neighbours sharing its display, frontmost first. Panes with no window are left
    /// empty rather than reusing a window, so nothing is moved twice.
    @MainActor
    static func apply(_ arrangement: Arrangement, to window: ManagedWindow) {
        let panes = arrangement.panes
        place(window, in: panes[0])
        guard panes.count > 1 else { return }

        let neighbours = WindowStore.shared.arrangementNeighbours(of: window)
        for (pane, neighbour) in zip(panes.dropFirst(), neighbours) {
            place(neighbour, in: pane)
        }
    }

    private static func place(_ window: ManagedWindow, in unit: CGRect) {
        guard let display = ScreenGeometry.owningDisplay(for: window.frame),
              let screen = ScreenGeometry.screen(for: display)
        else { return }

        let area = ScreenGeometry.cgVisibleFrame(of: screen)
        let target = CGRect(
            x: area.minX + unit.minX * area.width,
            y: area.minY + unit.minY * area.height,
            width: unit.width * area.width,
            height: unit.height * area.height
        )
        WindowActivator.setFrame(target, for: window)
    }
}
