import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel that floats above regular windows on one display.
final class DockPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DockController {
    let displayID: CGDirectDisplayID
    let model: DockPanelModel
    let panel: DockPanel

    private var isBoosting = false
    private var visibleFrame: NSRect
    private var shrinkWorkItem: DispatchWorkItem?
    private var contentHeightObserver: AnyCancellable?
    private var cardRectsObserver: AnyCancellable?
    /// Nothing to show on this display at all.
    private var isEmpty = false
    /// The active window fills this display, so the resting sliver would sit on top of
    /// content the user gave the whole screen to. The dock still reveals on hover.
    private var hidesPeek = false

    init(screen: NSScreen) {
        displayID = ScreenGeometry.displayID(of: screen)
        model = DockPanelModel(displayID: displayID)
        visibleFrame = screen.visibleFrame

        panel = DockPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // The panel is a rectangle, but the cards inside it are islands. Rather than swallow
        // every click that lands on the panel, it is made click-through wherever there is no
        // card under the pointer — see `updateClickThrough`.
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        let root = DockStripView(model: model)
            .environmentObject(WindowStore.shared)
            .environmentObject(Preferences.shared)

        let hosting = PanelHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        updateFrame(for: screen)
        panel.orderFrontRegardless()

        // The collapsed frame depends on the measured stack, which only exists after SwiftUI
        // has laid out — and changes whenever a window is added, removed, or resized.
        contentHeightObserver = model.$contentHeight
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, !self.model.isRevealed else { return }
                Task { @MainActor in self.applyFrame(revealed: false) }
            }

        // A card appearing, growing or sliding under a stationary pointer changes the answer
        // without any mouse event to recompute it from.
        cardRectsObserver = model.$cardRects
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateClickThrough(pointer: NSEvent.mouseLocation) }
            }
    }

    // MARK: - Geometry

    func updateFrame(for screen: NSScreen) {
        visibleFrame = screen.visibleFrame
        shrinkWorkItem?.cancel()
        shrinkWorkItem = nil
        applyFrame(revealed: model.isRevealed)
    }

    /// Extra room for the perspective overhang, hover lift, and directional shadow.
    private var revealedWidth: CGFloat {
        CGFloat(Preferences.shared.cardWidth) + Theme.panelPadding * 2 + 54
    }

    /// Just the visible sliver plus a little headroom for its shadow.
    private var collapsedWidth: CGFloat { Theme.peek + 22 }

    private func frame(revealed: Bool) -> NSRect {
        let width = revealed ? revealedWidth : collapsedWidth
        let x = Preferences.shared.edge == .left ? visibleFrame.minX : visibleFrame.maxX - width
        let full = NSRect(x: x, y: visibleFrame.minY, width: width, height: visibleFrame.height)
        guard !revealed else { return full }

        // Collapsed, the panel hugs the card stack rather than running the whole height of
        // the display. The panel is always hit-testable, so a full-height sliver swallowed
        // every click along that edge — including the stretches above and below the cards
        // where nothing is drawn, which left parts of the windows underneath unclickable.
        // A little headroom keeps the hover lift and shadow from being clipped.
        let content = min(model.contentHeight + 12, visibleFrame.height)
        guard content > 0 else { return full }
        return NSRect(x: x,
                      y: visibleFrame.midY - content / 2,
                      width: width,
                      height: content)
    }

    private func applyFrame(revealed: Bool) {
        panel.setFrame(frame(revealed: revealed), display: false)
    }

    /// The area the pointer must stay inside to keep the dock revealed.
    var hoverFrame: NSRect { frame(revealed: true).insetBy(dx: -10, dy: -10) }

    /// Lets clicks that miss every card reach whatever is behind the panel.
    ///
    /// Toggling from pointer events is only safe because the state is recomputed from the
    /// live pointer position on every move, on a 60ms poll, *and* whenever the cards
    /// themselves move — so a click can only land on a stale answer if the layout changed
    /// under a pointer that then clicked within the same frame.
    func updateClickThrough(pointer: NSPoint) {
        let solid = PanelHitTesting.isSolid(point: pointer, cards: model.cardRects, panel: panel.frame)
        if panel.ignoresMouseEvents == solid {
            panel.ignoresMouseEvents = !solid
            DebugLog.log("panel \(displayID): \(solid ? "takes" : "passes through") clicks at \(Int(pointer.x)),\(Int(pointer.y))")
        }
    }

    func triggerZone(for screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let thickness: CGFloat = 4
        let x = Preferences.shared.edge == .left ? visible.minX : visible.maxX - thickness
        return NSRect(x: x, y: visible.minY, width: thickness, height: visible.height)
    }

    // MARK: - Reveal

    /// An empty strip reserves no screen edge and cannot be revealed — there is nothing
    /// in it to reveal.
    func setEmpty(_ empty: Bool) {
        guard isEmpty != empty else { return }
        isEmpty = empty
        syncVisibility()
    }

    /// Hides the resting sliver without disabling the dock: hovering the edge still
    /// reveals it, it simply stops peeking over a screen-filling window.
    func setHidesPeek(_ hides: Bool) {
        guard hidesPeek != hides else { return }
        hidesPeek = hides
        guard !model.isRevealed else { return }
        syncVisibility()
    }

    /// True only when the dock cannot be revealed at all.
    var isSuppressed: Bool { isEmpty }

    private var shouldBeOnScreen: Bool {
        !isEmpty && (model.isRevealed || !hidesPeek)
    }

    private func syncVisibility() {
        if shouldBeOnScreen {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func setRevealed(_ revealed: Bool) {
        guard model.isRevealed != revealed else { return }
        shrinkWorkItem?.cancel()
        shrinkWorkItem = nil
        // The menu belongs to a card that is about to slide away.
        if !revealed { TileMenuController.shared.close() }

        if revealed {
            // Widen first so the cards have somewhere to slide into.
            applyFrame(revealed: true)
            model.isRevealed = true
            syncVisibility()
            if !isBoosting {
                isBoosting = true
                WindowStore.shared.beginBoost()
            }
        } else {
            model.isRevealed = false
            if isBoosting {
                isBoosting = false
                WindowStore.shared.endBoost()
            }
            // Stay wide, and on screen, until the cards have finished sliding back behind
            // the edge — otherwise a suppressed dock would blink out mid-animation.
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, !self.model.isRevealed else { return }
                    self.shrinkWorkItem = nil
                    self.applyFrame(revealed: false)
                    self.syncVisibility()
                }
            }
            shrinkWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.revealDuration, execute: item)
        }
    }

    func tearDown() {
        shrinkWorkItem?.cancel()
        shrinkWorkItem = nil
        if isBoosting {
            isBoosting = false
            WindowStore.shared.endBoost()
        }
        panel.orderOut(nil)
        panel.contentView = nil
    }
}
