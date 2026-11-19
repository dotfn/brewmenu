import BrewCore
import Foundation

actor HistoryStore {
    private let snapshotsDir: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// The newest `cacheLimit` snapshots, newest first — read once, then kept in step with
    /// `save`/`prune`/`reset`. Insights are recomputed whenever services are polled (every 30s while
    /// the popover is open), and decoding 90 files each time was the cost of that.
    private var cache: [Snapshot]?
    private static let cacheLimit = 90

    /// `directory` is injectable so tests use an isolated folder, not the real history.
    init(directory: URL? = nil) {
        snapshotsDir = (directory ?? FileManager.brewMenuSupportDirectory)
            .appendingPathComponent("snapshots", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        try? FileManager.default.createDirectory(
            at: snapshotsDir, withIntermediateDirectories: true
        )
    }

    // MARK: - Write

    func save(_ snapshot: Snapshot) throws {
        let filename = Self.filename(for: snapshot.timestamp)
        let url = snapshotsDir.appendingPathComponent(filename)
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        // Same minute, same file: the newer snapshot replaced the older one on disk.
        cache = cache.map { cached in
            Array(([snapshot] + cached.filter { Self.filename(for: $0.timestamp) != filename }).prefix(Self.cacheLimit))
        }
    }

    // MARK: - Read

    /// Returns up to `limit` snapshots, sorted newest first.
    func loadRecent(limit: Int = 90) throws -> [Snapshot] {
        if let cache, limit <= Self.cacheLimit { return Array(cache.prefix(limit)) }
        let recent = try snapshotURLs()
            .suffix(max(limit, Self.cacheLimit))
            .reversed()
            .compactMap { url -> Snapshot? in
                let data = try Data(contentsOf: url)
                return try? decoder.decode(Snapshot.self, from: data)
            }
        cache = Array(recent.prefix(Self.cacheLimit))
        return Array(recent.prefix(limit))
    }

    // MARK: - Reset

    /// Deletes and recreates the snapshots directory — used by Settings' "Reset All
    /// Data". Actor-isolated so it can't race an in-flight `save()`/`loadRecent()`
    /// the way a bare `FileManager.removeItem` from outside the actor would, and
    /// (unlike deleting the folder directly) always leaves `snapshotsDir` existing
    /// afterward — `init()` only creates it once, so without recreating it here every
    /// later `save()` this session would silently fail via its `try?`.
    func reset() {
        cache = nil
        try? FileManager.default.removeItem(at: snapshotsDir)
        try? FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
    }

    // MARK: - Pruning

    /// Deletes snapshots older than `days` days. Called once per session on startup.
    func prune(olderThan days: Int = 30) throws {
        cache = nil
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let urls = try snapshotURLs()
        for url in urls {
            guard let date = Self.date(from: url.lastPathComponent), date < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Private

    /// All snapshot URLs in the directory, sorted oldest first by filename.
    private func snapshotURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Filename format: `2026-06-30T14-05.json` — sortable, filesystem-safe.
    private static func filename(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .appending(".json")
    }

    private static func date(from filename: String) -> Date? {
        let withoutExt = filename.replacingOccurrences(of: ".json", with: "")
        // Restore colons only in the time portion (after "T") — range must be derived from
        // withoutExt, not from filename, to avoid an out-of-bounds crash caused by the
        // shorter endIndex after removing the extension.
        guard let tIdx = withoutExt.firstIndex(of: "T") else { return nil }
        let timeRange = withoutExt.index(after: tIdx) ..< withoutExt.endIndex
        let name = withoutExt.replacingOccurrences(of: "-", with: ":", range: timeRange)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.date(from: name)
    }
}
