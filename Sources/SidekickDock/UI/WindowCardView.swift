import AppKit
import SwiftUI

/// A single window preview, tilted in 3D so the strip reads like Stage Manager's
/// angled cards rather than a flat list.
struct WindowCardView: View {
    let window: ManagedWindow
    let width: CGFloat
    let showTitle: Bool
    let isLeftEdge: Bool
    let isRevealed: Bool
    /// True when the pointer is on this card. Held by the strip rather than by the card:
    /// a card that tracked its own hover could be left stuck at hover size, because the exit
    /// event never arrives if the card moves out from under a stationary pointer — which is
    /// exactly what happens when a window is minimised from the card's own controls.
    let isHovered: Bool
    /// True when another card in the strip is hovered, so this one recedes slightly.
    let isDimmed: Bool
    let onHoverChange: (Bool) -> Void
    let onActivate: () -> Void

    @EnvironmentObject private var store: WindowStore
    @State private var isPressed = false

    private var preview: NSImage? { store.thumbnail(for: window) }

    private var aspectRatio: CGFloat {
        CardGeometry.aspectRatio(image: preview?.size, windowAspect: window.aspectRatio)
    }

    private var size: CGSize {
        CardGeometry.size(width: width, aspectRatio: aspectRatio)
    }

    /// A tall window's card is narrower than the strip so its picture is never cut.
    private var cardWidth: CGFloat { size.width }

    private var height: CGFloat { size.height }

    var body: some View {
        card
            .scaleEffect(scale, anchor: isLeftEdge ? .leading : .trailing)
            .offset(x: slideIn)
            .zIndex(isHovered ? 1 : 0)
            .animation(Theme.hover, value: isHovered)
            .animation(Theme.hover, value: isDimmed)
            .animation(Theme.hover, value: isPressed)
            .contentShape(Rectangle())
            // One gesture, not two. A separate `.onTapGesture` competes with this drag for
            // the same mouse-down, and SwiftUI resolves that race by arbitration — which is
            // why some clicks silently did nothing. Handling press and click in a single
            // gesture removes the arbitration entirely.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { value in
                        isPressed = false
                        // A click, not a drag off the card.
                        let drift = max(abs(value.translation.width), abs(value.translation.height))
                        if drift < 10 { onActivate() }
                    }
            )
            .onHover { hovering in
                onHoverChange(hovering)
            }
            .help(helpText)
            // Layered after the card's gesture so a click on a light is handled by the light
            // and never falls through to activation.
            .overlay(alignment: .topLeading) {
                if isRevealed && isHovered {
                    trafficLights
                        .padding(.leading, trafficLightInset)
                        .padding(.top, 2)
                        .transition(.opacity)
                }
            }
            .contextMenu {
                Button("Bring to Front", action: onActivate)
                if store.raisableSiblings(of: window).count > 1 {
                    Button("Show All Windows") { store.showAllWindows(window) }
                }
                Divider()
                if window.canMinimize {
                    Button("Minimise Window") { store.minimize(window) }
                }
                Button("Close Window") { store.close(window) }
                Divider()
                Button("Quit \(window.appName)") { store.quitApp(window) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.appName): \(window.displayTitle)")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Card

    private var card: some View {
        ZStack(alignment: badgeAlignment) {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color.black.opacity(0.28))

            if let image = preview {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: height)
                    .clipped()
            } else if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .frame(width: cardWidth, height: height)
                    .opacity(0.65)
            }

            sheen
            appBadge.padding(7)
        }
        .frame(width: cardWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(borderGradient, style: borderStroke)
        }
        .opacity(window.isMinimized ? 0.62 : 1)
        // A tight contact shadow plus a soft one below. Both cast straight down: a shadow
        // thrown sideways, away from the screen edge, pools between the cards and the panel
        // edge into a grey band beside the strip that grows and shrinks with the stack.
        .shadow(color: .black.opacity(0.28), radius: 5, y: 3)
        .shadow(
            color: .black.opacity(isRevealed ? (isHovered ? 0.42 : 0.3) : 0),
            radius: isHovered ? 20 : 14,
            y: isHovered ? 14 : 9
        )
        .overlay(alignment: titleAlignment) {
            // Not while collapsed: the chip is laid out against the card, and the panel is
            // then only as wide as the sliver, so the title is clipped to a few characters.
            if showTitle && isHovered && isRevealed {
                titleChip
                    .fixedSize()
                    .offset(y: 26)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// A faint diagonal highlight, as if a light source sits above the angled card.
    ///
    /// The *direction* mirrors with the edge, but the strength must not: it was a third as
    /// strong on the right from the very first commit, and since this shading is most of what
    /// makes a card read as tilted, a right-hand dock looked like it sat at a shallower angle
    /// than a left-hand one even though both are rotated by exactly the same degrees.
    private var sheen: some View {
        LinearGradient(
            colors: [
                Color.white.opacity(0.14),
                Color.white.opacity(0.02),
                Color.black.opacity(0.10)
            ],
            startPoint: isLeftEdge ? .topTrailing : .topLeading,
            endPoint: isLeftEdge ? .bottomLeading : .bottomTrailing
        )
        .blendMode(.softLight)
        .allowsHitTesting(false)
    }

    private var titleChip: some View {
        Text(window.displayTitle)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: cardWidth * 1.2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    }
            }
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
            .allowsHitTesting(false)
    }

    private var appBadge: some View {
        Group {
            if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary)
                    .frame(width: 24, height: 24)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
    }

    // MARK: - Window controls

    /// The same three controls the window itself carries, in the same order and colours, so
    /// they read as the window's own rather than as dock chrome.
    private var trafficLights: some View {
        WindowTrafficLights(window: window, onHoverChange: onHoverChange)
    }

    // MARK: - Geometry

    private var scale: CGFloat {
        if isPressed { return 0.97 }
        if isHovered { return 1.06 }
        return isDimmed ? 0.97 : 1
    }

    /// Hovered cards step in from the edge, as though lifting off the stack.
    private var slideIn: CGFloat {
        guard isHovered else { return 0 }
        return isLeftEdge ? 8 : -8
    }

    private var borderGradient: LinearGradient {
        if window.isActive {
            return LinearGradient(
                colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        // The dotted edge is the only cue a minimised card carries, so it is drawn brighter
        // than a normal border — scattered dots read far weaker than a continuous line.
        if window.isMinimized {
            return LinearGradient(
                colors: [Color.white.opacity(0.85), Color.white.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        let top = isHovered ? 0.34 : 0.18
        return LinearGradient(
            colors: [Color.white.opacity(top), Color.white.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// A minimised card is outlined in dots rather than a solid line: the same "this is a
    /// placeholder, the real thing is put away" language as a dashed drop target.
    private var borderStroke: StrokeStyle {
        if window.isMinimized {
            return StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [0.01, 4])
        }
        return StrokeStyle(lineWidth: window.isActive ? 3 : 1)
    }

    /// Horizontal inset for the traffic lights, measured rather than derived.
    ///
    /// The cluster is positioned against the layout frame, but the strip's 3D rotation
    /// shears the card away from those bounds, so the visible top-left corner is not where
    /// the frame says it is. Crucially the tilt is *mirrored* for the right-hand strip, so
    /// the correction has to mirror too: screenshots put the visible corner about 9.5pt
    /// inside the frame on the left strip and about 13pt outside it on the right, and both
    /// values here land the cluster the same ~8.5pt inside the corner it belongs to.
    private var trafficLightInset: CGFloat { isLeftEdge ? 18 : -8 }

    private var titleAlignment: Alignment { .bottom }

    /// The badge sits on whichever side stays visible when the strip is tucked away, so a
    /// collapsed card can still be identified from its sliver alone.
    private var badgeAlignment: Alignment { isLeftEdge ? .bottomTrailing : .bottomLeading }

    private var helpText: String {
        window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"
    }
}
