import Foundation

actor SettingsStore {
    private let fileURL: URL
    private(set) var settings: AppSettings = AppSettings()

    /// `directory` is injectable so tests can point the store at an isolated temp
    /// directory instead of the real Application Support folder — same pattern as
    /// `InstalledPackagesCache`/`HomebrewAPICache`.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.brewMenuSupportDirectory
        // Ensure directory exists — if this fails the store falls back to in-memory defaults.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("settings.json")
        if let loaded = Self.load(from: fileURL) {
            self.settings = loaded
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            // Present but unreadable: keep the bytes aside. Otherwise the next save() writes
            // defaults over them, and whatever the user had configured is gone for good.
            let backup = dir.appendingPathComponent("settings.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    func save(_ newSettings: AppSettings) throws {
        settings = newSettings
        let data = try JSONEncoder().encode(newSettings)
        // Re-create directory in case it was deleted after init.
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Private

    private static func load(from url: URL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }
}
