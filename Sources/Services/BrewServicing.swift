protocol BrewServicing: Actor {
    func bootstrap(customBrewPath: String?) async throws
    func fetchOutdated() async throws -> [OutdatedPackage]
    func fetchInstalledCasks() async throws -> [CaskEntry]
    func fetchServices() async throws -> [ServiceEntry]
    func runDoctor() async throws -> [DoctorWarning]
    func runCleanupDryRun() async throws -> Int64
    func runUpdate() async throws
    func runUpgrade(_ name: String) async throws
    func runUpgrade(names: [String], onLine: @escaping @Sendable (String) -> Void) async throws
    func runUpgradeAll(onLine: @escaping @Sendable (String) -> Void) async throws
    func startService(_ name: String) async throws
    func stopService(_ name: String) async throws
}

extension BrewService: BrewServicing {}
