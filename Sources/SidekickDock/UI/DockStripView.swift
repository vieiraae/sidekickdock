import AppKit
import SwiftUI

@MainActor
final class DockPanelModel: ObservableObject {
    @Published var isRevealed = false
    /// Measured height of the card stack. The collapsed panel hugs this instead of running
    /// the full height of the display, so the rest of the screen edge stays clickable.
    /// Measured rather than computed: card heights follow each window's aspect ratio, so
    /// recalculating the layout here would drift from what SwiftUI actually lays out.
    @Published var contentHeight: CGFloat = 0
    /// Where the cards are, in the panel's own coordinates with y running down.
    ///
    /// The panel is a plain rectangle running the height of the display, but the cards inside
    /// it are islands with desktop showing between and around them. Without knowing where they
    /// are the panel has to swallow every click that lands on it, including the ones meant for
    /// a window behind it — the close button of a full-width window, or the desktop in the gap
    /// between two cards.
    @Published var cardRects: [CGRect] = []
    let displayID: CGDirectDisplayID

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }
}

struct DockStripView: View {
    @ObservedObject var model: DockPanelModel
    @EnvironmentObject private var store: WindowStore
    @EnvironmentObject private var prefs: Preferences

    @State private var hoveredID: CGWindowID?

    private var windows: [ManagedWindow] { store.windows(on: model.displayID) }
    private var stacks: [StripLayout.Stack] { store.stacks(on: model.displayID) }
    private var cardWidth: CGFloat { CGFloat(prefs.cardWidth) }
    private var isLeft: Bool { prefs.edge == .left }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack {
                    stack
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isLeft ? .leading : .trailing)
        }
        // No edge padding while collapsed. The sliver is the click target then, and the
        // panel is only `peek + 22` wide, so a 10pt inset made a fifth of it dead — the
        // fifth nearest the screen edge, which is exactly where the pointer arrives. That
        // is what made clicks seem to drop at random.
        .padding(isLeft ? .leading : .trailing, model.isRevealed ? 10 : 0)
        .offset(x: revealOffset)
        .opacity(windows.isEmpty ? 0 : 1)
        .animation(Theme.reveal, value: model.isRevealed)
        .animation(Theme.reveal, value: windows.count)
        .onPreferenceChange(CardRectsKey.self) { rects in
            Task { @MainActor in model.cardRects = rects }
        }
        .onChange(of: model.isRevealed) { _, revealed in
            if !revealed { hoveredID = nil }
        }
    }

    /// The cards float directly over the desktop — Stage Manager has no container chrome.
    /// The 3D rotation is applied to the whole strip rather than to each card, so every
    /// card shares one vanishing point. That is what produces the real thing's signature
    /// look: cards further from the centre are progressively more sheared.
    private var stack: some View {
        // Cards are flush on the side away from the screen edge. A tall window's card is
        // narrower than the rest, and it is the far edge that shows while the strip is
        // collapsed — aligning there keeps every sliver the same width.
        VStack(alignment: isLeft ? .trailing : .leading, spacing: Theme.cardSpacing) {
            ForEach(stacks) { appStack in
                appCards(appStack)
                    // The hovered card's title chip hangs below it, into the next pile. Piles
                    // are siblings, so without this the pile after it is drawn over the chip
                    // and the title reads as being underneath the next preview.
                    .zIndex(appStack.windows.contains { $0.id == hoveredID } ? 1 : 0)
            }
        }
        .padding(.vertical, Theme.panelPadding)
        .padding(isLeft ? .trailing : .leading, 22)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { model.contentHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in
                        model.contentHeight = height
                    }
            }
        )
        .rotation3DEffect(
            .degrees(tilt),
            axis: (x: 0, y: 1, z: 0),
            anchor: .center,
            perspective: Theme.perspective
        )
        // A backstop for the whole stack: if a card's own exit never arrives — it can be
        // missed when the layout shifts under a still pointer — leaving the stack still
        // clears the hover.
        .onContinuousHover { phase in
            if case .ended = phase { hoveredID = nil }
        }
        .animation(Theme.reveal, value: model.isRevealed)
    }

    /// One app's windows, laid over one another like a hand of cards: the frontmost window is
    /// whole at the bottom of the pile and every window behind it shows its top half, so a
    /// stack says how many windows an app has and still lets each one be recognised.
    ///
    /// Drawn back to front, because a later sibling is drawn over an earlier one — which also
    /// makes the exposed half of each card its own click target, with no overlap to arbitrate.
    private func appCards(_ appStack: StripLayout.Stack) -> some View {
        let ordered = appStack.backToFront
        return VStack(alignment: isLeft ? .trailing : .leading, spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, window in
                card(window)
                    // Negative padding rather than a ZStack with offsets: the pile still has a
                    // real height, so the panel hugs it and the strip scrolls when it is long.
                    .padding(.top, index == 0 ? 0 : -overlap(of: ordered[index - 1]))
                    // Padding rather than an offset for the sideways step, so a card's
                    // measured rectangle — which is what makes the panel solid where a card
                    // is and click-through everywhere else — stays where the card is drawn.
                    //
                    // Collapsed as well as revealed, so a pile still reads as a pile from the
                    // sliver alone. It costs the deeper cards some of their peek, and with it
                    // their app badge, but every window in a pile belongs to the same app and
                    // the front card of the pile keeps the full peek — so the badge that
                    // identifies it is never the one that gets clipped.
                    .padding(
                        isLeft ? .trailing : .leading,
                        StripLayout.stagger(behindFront: ordered.count - 1 - index)
                    )
                    // A hovered card lifts clear of the pile, so pointing at a window behind
                    // another shows the whole of it rather than the half that was exposed.
                    .zIndex(hoveredID == window.id ? Double(ordered.count) : Double(index))
            }
        }
    }

    private func card(_ window: ManagedWindow) -> some View {
        WindowCardView(
            window: window,
            width: cardWidth,
            showTitle: prefs.showTitles,
            isLeftEdge: isLeft,
            isRevealed: model.isRevealed,
            isHovered: hoveredID == window.id,
            isDimmed: hoveredID != nil && hoveredID != window.id
        ) { hovering in
            if hovering {
                hoveredID = window.id
            } else if hoveredID == window.id {
                hoveredID = nil
            }
        } onActivate: {
            store.activate(window)
        }
        .transition(.asymmetric(
            insertion: .scale(scale: 0.85, anchor: isLeft ? .leading : .trailing).combined(with: .opacity),
            removal: .scale(scale: 0.8).combined(with: .opacity)
        ))
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardRectsKey.self, value: [proxy.frame(in: .global)])
            }
        )
    }

    /// How much of `window`'s card the next one in its stack covers. The card's height comes
    /// from the picture it is about to draw, exactly as the card itself computes it, so the
    /// pile never drifts from what is on screen.
    private func overlap(of window: ManagedWindow) -> CGFloat {
        let aspect = CardGeometry.aspectRatio(
            image: store.thumbnail(for: window)?.size, windowAspect: window.aspectRatio
        )
        return StripLayout.overlap(
            cardHeight: CardGeometry.height(width: cardWidth, aspectRatio: aspect)
        )
    }
    /// Positive angles bring the leading edge forward, which is the direction the real
    /// Stage Manager tilts its left-hand strip.
    private var tilt: Double {
        let magnitude = model.isRevealed ? Theme.tiltRevealed : Theme.tiltCollapsed
        return isLeft ? magnitude : -magnitude
    }

    /// Tucks the strip off the edge, leaving a slim sliver peeking like Stage Manager.
    private var revealOffset: CGFloat {
        guard !model.isRevealed else { return 0 }
        let hidden = cardWidth - Theme.peek
        return isLeft ? -hidden : hidden
    }
}

/// Collects every card's rectangle so the panel knows which parts of itself are solid.
private struct CardRectsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}
