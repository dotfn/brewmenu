import BrewCore
import Foundation

/// Appends structured log lines to brewmenu.log.
/// Rotates to brewmenu.log.1 when the file exceeds 5 MB (one backup kept).
actor BrewLogger {
    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    static let shared = BrewLogger()

    private let logURL: URL
    private let backupURL: URL
    private static let maxBytes = 5 * 1024 * 1024 // 5 MB
    private let formatter: ISO8601DateFormatter

    /// `directory` is injectable so tests write to a temp folder, not the real Logs folder.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.brewMenuLogsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("brewmenu.log")
        backupURL = dir.appendingPathComponent("brewmenu.log.1")
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
    }

    // MARK: - Public

    func log(_ message: String, _ level: Level = .info) {
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) [\(level.rawValue)] \(message)\n"
        rotateIfNeeded()
        append(line)
    }

    // MARK: - Private

    private func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        guard let size = attrs?[.size] as? Int, size >= Self.maxBytes else { return }
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: logURL, to: backupURL)
    }

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // The folder can be removed under us (Reset All Data clears it), so recreate it.
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: logURL, options: [])
        }
    }
}
