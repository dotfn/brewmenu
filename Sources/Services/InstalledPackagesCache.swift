import Foundation

/// Last-known `installedPackages`/`taps`, persisted to disk so `DashboardViewModel.load()`
/// can paint Home/Installed instantly on every launch after the first — instead of every
/// launch blocking on a fresh `brew info --json=v2 --installed` subprocess spawn — then
/// silently refresh underneath once the real fetch completes. Stale-while-revalidate, same
/// actor + JSON-file pattern as `SettingsStore`/`HomebrewAPICache`.
actor InstalledPackagesCache {
    private struct CacheFile: Codable {
        var installedPackages: [InstalledPackage] = []
        var taps: [Tap] = []
    }

    private let fileURL: URL
    private(set) var installedPackages: [InstalledPackage]
    private(set) var taps: [Tap]

    /// `directory` is injectable so tests can point the cache at an isolated temp
    /// directory instead of the real Application Support folder.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.brewMenuSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("installed-cache.json")
        let loaded = Self.load(from: fileURL) ?? CacheFile()
        self.installedPackages = loaded.installedPackages
        self.taps = loaded.taps
    }

    func save(installedPackages: [InstalledPackage], taps: [Tap]) {
        self.installedPackages = installedPackages
        self.taps = taps
        guard let data = try? JSONEncoder().encode(CacheFile(installedPackages: installedPackages, taps: taps)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> CacheFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }
}
