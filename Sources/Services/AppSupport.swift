import BrewCore
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

    /// The override from the environment, if set and non-empty — and, in a test run without one, a
    /// temporary folder of that run's own. Code a test reaches without passing its own directory
    /// (`BrewLogger.shared`, "Reset all data") used to read and write the user's real folders: a
    /// "Reset all data" test deleted their settings.json, caches and log on every `swift test`.
    static var environmentOverride: URL? {
        if let path = ProcessInfo.processInfo.environment["BREWMENU_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return testRunRoot
    }

    /// `swift test` runs Swift Testing in `swiftpm-testing-helper` and XCTest in `xctest`; Xcode
    /// sets `XCTestConfigurationFilePath`. None of them is the app.
    private static let testRunRoot: URL? = {
        let process = ProcessInfo.processInfo
        let isTestRun = ["swiftpm-testing-helper", "xctest"].contains(process.processName)
            || process.environment["XCTestConfigurationFilePath"] != nil
        guard isTestRun else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewMenuTests-\(process.processIdentifier)", isDirectory: true)
    }()

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

extension UserDefaults {
    /// Where the app keeps its few UserDefaults flags (`hasCompletedOnboarding`). An isolated run
    /// (`BREWMENU_DATA_DIR`) gets its own suite so it never flips the real app's flags. Launch
    /// arguments (`-hasCompletedOnboarding YES`) still apply: every suite searches the argument domain.
    static var brewMenu: UserDefaults {
        guard BrewMenuDataRoots.environmentOverride != nil else { return .standard }
        return UserDefaults(suiteName: "BrewMenu.isolated") ?? .standard
    }
}
