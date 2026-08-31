import Foundation

/// Opt-in diagnostics, written to ~/Library/Logs/SidekickDock.log.
///
/// Enabled with `defaults write com.sidekickdock.app debugLogging -bool YES` or by
/// setting SIDEKICK_DEBUG=1 in the environment. Off by default so the release build
/// does no file I/O on the click path.
enum DebugLog {
    static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["SIDEKICK_DEBUG"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "debugLogging")
    }()

    private static let queue = DispatchQueue(label: "dock.debug-log", qos: .utility)

    private static let maxBytes: UInt64 = 8 * 1024 * 1024

    private static let url: URL? = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        return base?.appending(path: "Logs/SidekickDock.log")
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled, let url else { return }
        let line = "\(stamp.string(from: Date())) \(message())\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let end = (try? handle.seekToEnd()) ?? 0
                // A session left running with logging on would otherwise grow without
                // limit. Start again rather than keep an unbounded history.
                if end > maxBytes {
                    try? handle.truncate(atOffset: 0)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Owner-only: the log names every window the user touches, which is their
                // documents, their pages and who they are messaging.
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: data,
                    attributes: [.posixPermissions: 0o600]
                )
            }
        }
    }
}
