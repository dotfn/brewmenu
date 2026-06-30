import Foundation

actor HistoryStore {
    private let snapshotsDir: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        self.snapshotsDir = appSupport
            .appendingPathComponent("BrewMenu", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = .prettyPrinted
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
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
    }

    // MARK: - Read

    /// Returns up to `limit` snapshots, sorted newest first.
    func loadRecent(limit: Int = 90) throws -> [Snapshot] {
        let urls = try snapshotURLs()
        return try urls
            .suffix(limit)
            .reversed()
            .compactMap { url -> Snapshot? in
                let data = try Data(contentsOf: url)
                return try? decoder.decode(Snapshot.self, from: data)
            }
    }

    // MARK: - Pruning

    /// Deletes snapshots older than `days` days. Called once per session on startup.
    func prune(olderThan days: Int = 30) throws {
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
        let timeRange = withoutExt.index(after: tIdx)..<withoutExt.endIndex
        let name = withoutExt.replacingOccurrences(of: "-", with: ":", range: timeRange)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.date(from: name)
    }
}
 
