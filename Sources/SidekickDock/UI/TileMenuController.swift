import AppKit
import SwiftUI

/// The Move & Resize menu shown when the pointer rests on a card's green button.
///
/// It lives in its own panel rather than inside the strip: the strip is only as wide as a
/// card, and a menu drawn inside it would be clipped to that width.
@MainActor
final class TileMenuController {
    static let shared = TileMenuController()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var shownFor: CGWindowID?

    private init() {}

    func show(for window: ManagedWindow, at location: NSPoint) {
        hideWork?.cancel()
        hideWork = nil

        if shownFor == window.id, panel != nil { return }
        close()
        shownFor = window.id

        let content = TileMenuView(window: window) { [weak self] in
            self?.close()
        } onHoverChanged: { [weak self] inside in
            if inside { self?.hideWork?.cancel() } else { self?.scheduleHide() }
        }

        let hosting = PanelHostingView(rootView: content)
        hosting.layout()
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the strip, which floats itself.
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        panel.setFrame(NSRect(origin: origin(for: size, near: location), size: size), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        hideWork = work
        // Long enough to cross the gap between the button and the menu.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func close() {
        hideWork?.cancel()
        hideWork = nil
        shownFor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Keeps the menu on screen, opening below the pointer and flipping when there is no room.
    private func origin(for size: NSSize, near location: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return location }

        var x = location.x - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)

        var y = location.y - size.height - 14
        if y < visible.minY + 8 { y = location.y + 14 }
        return NSPoint(x: x, y: y)
    }
}

private struct TileMenuView: View {
    let window: ManagedWindow
    let onPick: () -> Void
    let onHoverChanged: (Bool) -> Void

    private let halves: [WindowTiler.Tile] = [.left, .right, .top, .bottom]
    private let quarters: [WindowTiler.Tile] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    private let arrangements = WindowTiler.Arrangement.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Move & Resize") {
                row { ForEach(halves) { tile($0) } }
                row { ForEach(quarters) { tile($0) } }
            }

            Divider().opacity(0.5)

            section("Fill & Arrange") {
                row { ForEach(arrangements) { arrangement($0) } }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12))
                }
        }
        .onHover { onHoverChanged($0) }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
    }

    private func tile(_ tile: WindowTiler.Tile) -> some View {
        TileButton(panes: [tile.unitRect], label: tile.label) {
            WindowTiler.apply(tile, to: window)
            onPick()
        }
    }

    private func arrangement(_ arrangement: WindowTiler.Arrangement) -> some View {
        TileButton(panes: arrangement.panes, label: arrangement.label) {
            WindowTiler.apply(arrangement, to: window)
            onPick()
        }
    }
}

private struct TileButton: View {
    /// The first pane is this window's; any others belong to the neighbours an arrangement
    /// moves alongside it, and are drawn dimmer to say so.
    let panes: [CGRect]
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    private let size = CGSize(width: 30, height: 22)

    var body: some View {
        // Drawn rather than taken from SF Symbols: the quarters and the arrangements have no
        // symbol of their own, and a drawn tile shows the layout exactly.
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)

            ForEach(Array(panes.enumerated()), id: \.offset) { index, pane in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(index == 0 ? 0.85 : 0.3))
                    .frame(
                        width: size.width * pane.width - 3,
                        height: size.height * pane.height - 3
                    )
                    .offset(
                        x: size.width * pane.minX + 1.5,
                        y: size.height * pane.minY + 1.5
                    )
            }
        }
        .frame(width: size.width, height: size.height)
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.14 : 0))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: action)
        .help(label)
        .accessibilityLabel(label)
    }
}
