import Foundation

actor SettingsStore {
    private let fileURL: URL
    private(set) var settings: AppSettings = AppSettings()

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = appSupport.appendingPathComponent("BrewMenu", isDirectory: true)
        // Ensure directory exists — if this fails the store falls back to in-memory defaults.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("settings.json")
        if let loaded = Self.load(from: fileURL) {
            self.settings = loaded
            // Existing install (settings.json present) whose JSON predates the onboarding
            // flag: skip the wizard so returning users aren't interrupted.
            if !loaded.hasCompletedOnboarding {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            }
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
