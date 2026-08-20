import AppKit
import Combine

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let edge = "dock.edge"
        static let cardWidth = "dock.cardWidth"
        static let showTitles = "dock.showTitles"
        static let includeMinimized = "dock.includeMinimized"
        static let revealDelay = "dock.revealDelay"
        static let replaceCommandTab = "dock.replaceCommandTab"
    }

    enum Edge: String, CaseIterable, Identifiable {
        case left, right
        var id: String { rawValue }
        var label: String { self == .left ? "Left" : "Right" }
    }

    @Published var edge: Edge {
        didSet { defaults.set(edge.rawValue, forKey: Key.edge) }
    }

    @Published var cardWidth: Double {
        didSet { defaults.set(cardWidth, forKey: Key.cardWidth) }
    }

    @Published var showTitles: Bool {
        didSet { defaults.set(showTitles, forKey: Key.showTitles) }
    }

    @Published var includeMinimized: Bool {
        didSet { defaults.set(includeMinimized, forKey: Key.includeMinimized) }
    }

    /// Seconds the pointer must rest in the trigger zone before the dock reveals.
    @Published var revealDelay: Double {
        didSet { defaults.set(revealDelay, forKey: Key.revealDelay) }
    }

    /// Take over ⌘Tab and show the dock's own switcher instead of the system one.
    @Published var replaceCommandTab: Bool {
        didSet { defaults.set(replaceCommandTab, forKey: Key.replaceCommandTab) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.edge: Edge.left.rawValue,
            Key.cardWidth: 168.0,
            Key.showTitles: true,
            Key.includeMinimized: true,
            Key.revealDelay: 0.18,
            Key.replaceCommandTab: true
        ])
        edge = Edge(rawValue: defaults.string(forKey: Key.edge) ?? "left") ?? .left
        cardWidth = defaults.double(forKey: Key.cardWidth)
        showTitles = defaults.bool(forKey: Key.showTitles)
        includeMinimized = defaults.bool(forKey: Key.includeMinimized)
        revealDelay = defaults.double(forKey: Key.revealDelay)
        replaceCommandTab = defaults.bool(forKey: Key.replaceCommandTab)
    }
}
