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
        .onChange(of: model.isRevealed) { _, revealed in
            if !revealed { hoveredID = nil }
        }
    }

    /// The cards float directly over the desktop — Stage Manager has no container chrome.
    /// The 3D rotation is applied to the whole strip rather than to each card, so every
    /// card shares one vanishing point. That is what produces the real thing's signature
    /// look: cards further from the centre are progressively more sheared.
    private var stack: some View {
        VStack(alignment: isLeft ? .leading : .trailing, spacing: Theme.cardSpacing) {
            ForEach(windows) { window in
                WindowCardView(
                    window: window,
                    width: cardWidth,
                    showTitle: prefs.showTitles,
                    isLeftEdge: isLeft,
                    isRevealed: model.isRevealed,
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
        .animation(Theme.reveal, value: model.isRevealed)
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
