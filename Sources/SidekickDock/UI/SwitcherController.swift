import AppKit
import SwiftUI

/// The dock's stand-in for the system application switcher.
///
/// It cycles *windows* rather than app groups — the same premise as the strip — and reuses the
/// live previews the strip already captures, so nothing extra is grabbed when it opens.
@MainActor
final class SwitcherController: ObservableObject {
    static let shared = SwitcherController()

    /// The windows in the order they were snapshotted when cycling began, grouped by display.
    /// Deliberately frozen: a refresh mid-cycle must never move the item under the selection.
    @Published private(set) var groups: [WindowStore.DisplayGroup] = []
    @Published private(set) var selection = 0

    /// The same windows flattened, which is what the selection indexes into.
    private(set) var items: [ManagedWindow] = []

    private(set) var isEngaged = false
    private var panel: NSPanel?
    private var showWork: DispatchWorkItem?
    /// Where the pointer was when the overlay appeared; cleared once it moves.
    private var pointerAnchor: NSPoint?
    /// Bumped on every open, so a late focus answer cannot land in a later cycle.
    private var session = 0
    /// Whether the user has moved the selection since opening. A live focus answer must not
    /// pull the selection back from wherever they have already cycled to.
    private var hasMoved = false
    /// Indices into `items`, newest-used first. Frozen with the snapshot so the traversal
    /// order cannot shift midway through a cycle.
    private var recency: [Int] = []

    private init() {}

    // MARK: - Cycling

    /// Tab traversal: walks the windows in most-recently-used order.
    ///
    /// The grid itself stays in spatial order so cards never move under the pointer, which
    /// means the highlight sometimes hops rather than stepping sideways. That is the point:
    /// one press should always land on the window you were last in, wherever it sits.
    func step(by delta: Int) {
        // The first press only opens the switcher, on the window in use. Moving on that press
        // as well would mean the active window could never be the choice, and there would be
        // no way to open the switcher and simply look at it.
        if !isEngaged {
            _ = begin()
            return
        }
        guard !items.isEmpty else { return }
        hasMoved = true
        selection = SwitcherIndex.stepInRecency(
            selection: selection, by: delta, recency: recency, count: items.count
        )
    }

    /// Arrow traversal: walks the grid as drawn, because arrows are about position.
    func stepSpatially(by delta: Int) {
        guard isEngaged, !items.isEmpty else { return }
        hasMoved = true
        selection = SwitcherIndex.wrap(selection, by: delta, count: items.count)
    }

    func commit() {
        guard isEngaged else { return }
        let chosen = items.indices.contains(selection) ? items[selection] : nil
        end()
        if let chosen {
            DebugLog.log("switcher: activate \(chosen.appName)#\(chosen.id)")
            WindowStore.shared.activate(chosen)
        }
    }

    func cancel() {
        guard isEngaged else { return }
        end()
    }

    /// Hover-select, ignored until the pointer has actually moved.
    ///
    /// The overlay opens centred on the display, frequently straight under a stationary
    /// pointer, and SwiftUI reports that as a hover — which would throw the selection onto
    /// whichever tile happened to land there rather than the window the user is on.
    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        if let anchor = pointerAnchor {
            let now = NSEvent.mouseLocation
            guard hypot(now.x - anchor.x, now.y - anchor.y) > 4 else { return }
            pointerAnchor = nil
        }
        selection = index
    }

    /// Maps a position inside a display group onto the flattened selection index.
    func flatIndex(group: Int, item: Int) -> Int {
        SwitcherIndex.flatIndex(group: group, item: item, groupCounts: groups.map(\.windows.count))
    }

    // MARK: - Lifecycle

    private func begin() -> Bool {
        let snapshot = WindowStore.shared.switcherGroups()
        let flattened = snapshot.flatMap(\.windows)
        guard flattened.count > 1 else { return false }

        groups = snapshot
        items = flattened
        // Open on the window in use. The enumerator marks the frontmost app's front window
        // active; the z-order is the fallback for the moment no window claims it.
        selection = flattened.firstIndex { $0.isActive }
            ?? flattened
                .enumerated()
                .filter { !$0.element.isMinimized && $0.element.zIndex != .max }
                .min { $0.element.zIndex < $1.element.zIndex }?
                .offset
            ?? 0
        // Grouping assigns each window to one display, so IDs should already be unique;
        // keeping the first occurrence rather than trapping means a surprise here costs a
        // slightly odd traversal order instead of a crash.
        let byID = Dictionary(flattened.enumerated().map { ($1.id, $0) }) { first, _ in first }
        recency = UsageHistory.shared.ordered(flattened.map(\.id)).compactMap { byID[$0] }

        isEngaged = true
        hasMoved = false
        session &+= 1
        adoptLiveFocus()

        // A quick ⌘Tab-and-release should switch without ever flashing a panel, so the
        // overlay only appears once the user is plainly holding the shortcut.
        let work = DispatchWorkItem { [weak self] in self?.present() }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        return true
    }

    /// Asks the focused application which window actually has focus, and moves the selection
    /// onto it.
    ///
    /// The snapshot's own active flag is up to a refresh interval old, so pressing ⌘Tab in the
    /// second after clicking a window opened the switcher on the *previous* one. The answer is
    /// fetched off the main actor rather than inline: this runs from the event tap, and a
    /// blocking Accessibility round trip there risks the window server disabling the tap.
    /// The overlay does not appear for 150ms, so a prompt answer lands before anything is
    /// drawn.
    private func adoptLiveFocus() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let generation = session

        Task.detached(priority: .userInitiated) {
            guard let focused = AXWindowID.focusedWindow(pid: pid) else { return }
            await MainActor.run {
                let controller = SwitcherController.shared
                guard controller.isEngaged,
                      controller.session == generation,
                      !controller.hasMoved,
                      let index = controller.items.firstIndex(where: { $0.id == focused })
                else { return }
                controller.selection = index
            }
        }
    }

    private func end() {
        isEngaged = false
        pointerAnchor = nil
        showWork?.cancel()
        showWork = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func present() {
        guard isEngaged, panel == nil else { return }

        let hosting = PanelHostingView(rootView: SwitcherView(controller: self))
        hosting.layout()

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above everything, including full-screen windows, the way a switcher must be.
        panel.level = .screenSaver
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        pointerAnchor = NSEvent.mouseLocation
        panel.setFrame(centred(hosting.fittingSize), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Always centred on the primary display. `NSScreen.main` is the screen holding the *key
    /// window*, not the primary one, which is why the overlay used to wander between displays.
    private static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    private func centred(_ size: NSSize) -> NSRect {
        let frame = Self.primaryScreen?.frame ?? NSRect(origin: .zero, size: size)
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    var maxWidth: CGFloat {
        (Self.primaryScreen?.visibleFrame.width ?? 1200) * 0.82
    }
}

private struct SwitcherView: View {
    @ObservedObject var controller: SwitcherController

    private let tile = CGSize(width: 148, height: 104)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Above the tiles and centred, like the system switcher's caption, so the eye
            // lands on the name without leaving the middle of the overlay.
            Text(selectedTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)

            ForEach(Array(controller.groups.enumerated()), id: \.element.id) { groupIndex, group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: group.isPrimary ? "laptopcomputer" : "display")
                            .font(.system(size: 11, weight: .semibold))
                        Text(group.name)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                            let flat = controller.flatIndex(group: groupIndex, item: index)
                            SwitcherTile(
                                window: window,
                                size: tile,
                                isSelected: flat == controller.selection
                            )
                            .onHover { if $0 { controller.select(flat) } }
                            .onTapGesture { controller.commit() }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14))
                }
        }
        .frame(maxWidth: controller.maxWidth)
    }

    private var columns: [GridItem] {
        let widest = controller.groups.map(\.windows.count).max() ?? 1
        let fits = Int((controller.maxWidth - 36) / (tile.width + 10))
        let perRow = max(1, min(widest, max(1, fits)))
        return Array(repeating: GridItem(.fixed(tile.width), spacing: 10), count: perRow)
    }

    private var selectedTitle: String {
        guard controller.items.indices.contains(controller.selection) else { return "" }
        let window = controller.items[controller.selection]
        return window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"
    }
}

private struct SwitcherTile: View {
    let window: ManagedWindow
    let size: CGSize
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.22))

            if let image = WindowStore.shared.thumbnail(for: window) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            } else if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            }

            if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .shadow(radius: 2, y: 1)
                    .padding(6)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.white.opacity(0.08),
                    style: borderStroke
                )
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.16 : 0))
        }
        .opacity(window.isMinimized ? 0.65 : 1)
        .contentShape(Rectangle())
    }

    /// Same language as the strip: a minimised window is outlined in dots, because the card
    /// is a placeholder for something that has been put away.
    private var borderStroke: StrokeStyle {
        if window.isMinimized {
            return StrokeStyle(lineWidth: isSelected ? 2.5 : 1.6, lineCap: .round, dash: [0.01, 4])
        }
        return StrokeStyle(lineWidth: isSelected ? 2.5 : 1)
    }
}
