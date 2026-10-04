import Foundation

/// Where BrewMenu keeps its files. Each root is `nil`-overridable so the app can run against a
/// throwaway folder: set `BREWMENU_DATA_DIR` and settings, history, caches and logs all land
/// under `<dir>/support`, `<dir>/caches` and `<dir>/logs`. Without it, the macOS locations below.
struct BrewMenuDataRoots: Equatable {
    let support: URL
    let caches: URL
    let logs: URL

    /// Pure resolution, so tests can cover the override without touching the real environment.
    static func resolve(override: URL?, fileManager: FileManager = .default) -> BrewMenuDataRoots {
        if let override {
            return BrewMenuDataRoots(
                support: override.appendingPathComponent("support", isDirectory: true),
                caches: override.appendingPathComponent("caches", isDirectory: true),
                logs: override.appendingPathComponent("logs", isDirectory: true)
            )
        }
        return BrewMenuDataRoots(
            // Application Support: data that can't be rebuilt — settings and history snapshots.
            support: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BrewMenu", isDirectory: true),
            // Caches: rebuildable — installed-package snapshot, catalogue responses, askpass helper.
            caches: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BrewMenu", isDirectory: true),
            // Logs: where macOS users look for an app's log.
            logs: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/BrewMenu", isDirectory: true)
        )
    }

    /// The override from the environment, if set and non-empty.
    static var environmentOverride: URL? {
        guard let path = ProcessInfo.processInfo.environment["BREWMENU_DATA_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var current: BrewMenuDataRoots {
        resolve(override: environmentOverride)
    }
}

extension FileManager {
    /// Settings and history (see `BrewMenuDataRoots`).
    static var brewMenuSupportDirectory: URL {
        BrewMenuDataRoots.current.support
    }

    /// Rebuildable data (see `BrewMenuDataRoots`). Caches are regenerated, never user data.
    static var brewMenuCachesDirectory: URL {
        BrewMenuDataRoots.current.caches
    }

    /// The app's log folder (see `BrewMenuDataRoots`).
    static var brewMenuLogsDirectory: URL {
        BrewMenuDataRoots.current.logs
    }
}
