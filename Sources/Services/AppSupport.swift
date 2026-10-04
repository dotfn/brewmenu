import Foundation

extension FileManager {
    /// `~/Library/Application Support/BrewMenu` — data that can't be rebuilt: settings and
    /// the history snapshots.
    static var brewMenuSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrewMenu", isDirectory: true)
    }

    /// `~/Library/Caches/BrewMenu` — rebuildable data: the installed-package snapshot, the
    /// catalogue responses, and the askpass helper (regenerated on every launch). macOS may
    /// purge it, and that costs one refetch, not user data.
    static var brewMenuCachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrewMenu", isDirectory: true)
    }

    /// `~/Library/Logs/BrewMenu` — where macOS users look for an app's log.
    static var brewMenuLogsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BrewMenu", isDirectory: true)
    }
}
