import Foundation

extension FileManager {
    /// `~/Library/Application Support/BrewMenu` — the shared root every on-disk
    /// store (settings, history, logs, caches, the askpass helper) writes under.
    static var brewMenuSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrewMenu", isDirectory: true)
    }
}
