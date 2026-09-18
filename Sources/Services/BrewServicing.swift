protocol BrewServicing: Actor {
    func bootstrap(customBrewPath: String?) async throws
    func waitUntilConfigured() async throws
    func fetchOutdated() async throws -> [OutdatedPackage]
    func fetchInstalledCasks() async throws -> [CaskEntry]
    func fetchInstalledPackages() async throws -> [InstalledPackage]
    func resolvePackage(_ name: String) async throws -> ResolvedPackage?
    func searchPackages(_ query: String) async throws -> [SearchResult]
    func fetchTaps() async throws -> [Tap]
    func fetchTapPackages(_ tap: String) async throws -> [SearchResult]
    func addTap(_ name: String, onLine: @escaping @Sendable (String) -> Void) async throws
    func removeTap(_ name: String) async throws
    func fetchServices() async throws -> [ServiceEntry]
    func runDoctor() async throws -> [DoctorWarning]
    func runCleanupDryRun() async throws -> Int64
    func runCleanup(onLine: @escaping @Sendable (String) -> Void) async throws
    func runAutoremoveDryRun() async throws -> [String]
    func runAutoremove(onLine: @escaping @Sendable (String) -> Void) async throws
    func runUpdate() async throws
    func runUpgrade(_ name: String) async throws
    func runUpgradeAll(onLine: @escaping @Sendable (String) -> Void) async throws
    /// `onProgress` fires with `curl`'s own in-place progress-meter text (e.g.
    /// `"###   42.3%"`) for cask/bottle downloads — `nil` (the default) for callers
    /// that only care about the completed log lines `onLine` already gives them.
    func installPackage(
        _ name: String,
        isCask: Bool,
        onLine: @escaping @Sendable (String) -> Void,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws
    func uninstallPackage(_ name: String, isCask: Bool, onLine: @escaping @Sendable (String) -> Void) async throws
    func startService(_ name: String) async throws
    func stopService(_ name: String) async throws
}

extension BrewServicing {
    func installPackage(_ name: String, isCask: Bool, onLine: @escaping @Sendable (String) -> Void) async throws {
        try await installPackage(name, isCask: isCask, onLine: onLine, onProgress: nil)
    }
}

extension BrewService: BrewServicing {}
