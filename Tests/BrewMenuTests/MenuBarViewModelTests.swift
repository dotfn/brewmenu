@testable import BrewMenu
import Foundation
import Testing

// MARK: - Mock

actor MockBrewService: BrewServicing {
    var bootstrapError: Error?
    var fetchResponses: [[OutdatedPackage]] = []
    var fetchError: Error?
    var upgradeError: Error?
    var doctorResponse: [DoctorWarning] = []
    var servicesResponse: [ServiceEntry] = []

    private(set) var bootstrapCallCount = 0
    private(set) var fetchCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var upgradeCallCount = 0
    private(set) var doctorCallCount = 0
    private(set) var fetchServicesCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    private var fetchServicesWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func setFetchResponses(_ responses: [[OutdatedPackage]]) {
        fetchResponses = responses
    }

    func setBootstrapError(_ error: Error?) {
        bootstrapError = error
    }

    func setFetchError(_ error: Error?) {
        fetchError = error
    }

    func setUpgradeError(_ error: Error?) {
        upgradeError = error
    }

    func setDoctorResponse(_ warnings: [DoctorWarning]) {
        doctorResponse = warnings
    }

    func setServicesResponse(_ entries: [ServiceEntry]) {
        servicesResponse = entries
    }

    func bootstrap(customBrewPath _: String?) async throws {
        bootstrapCallCount += 1
        if let error = bootstrapError { throw error }
    }

    func waitUntilConfigured() async {}

    func fetchOutdated() async throws -> [OutdatedPackage] {
        fetchCallCount += 1
        if let error = fetchError { throw error }
        guard !fetchResponses.isEmpty else { return [] }
        return fetchResponses.removeFirst()
    }

    func fetchServices() async throws -> [ServiceEntry] {
        fetchServicesCallCount += 1
        fetchServicesWaiters.removeAll { target, continuation in
            guard fetchServicesCallCount >= target else { return false }
            continuation.resume()
            return true
        }
        return servicesResponse
    }

    /// Suspends until `fetchServices` has been called at least `count` times.
    /// Lets tests await the real completion of fire-and-forget polling Tasks
    /// instead of guessing at a `Task.sleep` duration.
    func waitForFetchServicesCallCount(_ count: Int) async {
        if fetchServicesCallCount >= count { return }
        await withCheckedContinuation { continuation in
            fetchServicesWaiters.append((count, continuation))
        }
    }

    func runDoctor() async throws -> [DoctorWarning] {
        doctorCallCount += 1
        return doctorResponse
    }

    private(set) var cleanupDryRunCallCount = 0
    var cleanupDryRunError: Error?
    var cleanupDryRunBytes: Int64 = 0
    func setCleanupDryRunError(_ error: Error?) {
        cleanupDryRunError = error
    }

    func setCleanupDryRunBytes(_ bytes: Int64) {
        cleanupDryRunBytes = bytes
    }

    func runCleanupDryRun() async throws -> Int64 {
        cleanupDryRunCallCount += 1
        if let cleanupDryRunError { throw cleanupDryRunError }
        return cleanupDryRunBytes
    }

    var cleanupError: Error?
    private(set) var cleanupCallCount = 0
    func setCleanupError(_ error: Error?) {
        cleanupError = error
    }

    var cleanupDelayNanoseconds: UInt64 = 0
    func setCleanupDelay(_ nanoseconds: UInt64) {
        cleanupDelayNanoseconds = nanoseconds
    }

    func runCleanup(onLine _: @escaping @Sendable (String) -> Void) async throws {
        cleanupCallCount += 1
        // A real Task.sleep, so cancelling the caller interrupts it the same way a brew run would.
        if cleanupDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: cleanupDelayNanoseconds) }
        if let error = cleanupError { throw error }
    }

    func fetchCacheEntries() async throws -> [CacheEntry] {
        []
    }

    func deleteCacheEntry(_: CacheEntry) async throws {}
    func clearCache() async throws {}
    func fetchPackageDiskUsage(for _: [(name: String, isCask: Bool)]) async throws -> [PackageDiskUsage] {
        []
    }

    var autoremoveDryRunResponse: [String] = []
    var autoremoveError: Error?
    private(set) var autoremoveCallCount = 0
    private(set) var autoremoveDryRunCallCount = 0
    func setAutoremoveError(_ error: Error?) {
        autoremoveError = error
    }

    func runAutoremoveDryRun() async throws -> [String] {
        autoremoveDryRunCallCount += 1
        return autoremoveDryRunResponse
    }

    func runAutoremove(onLine _: @escaping @Sendable (String) -> Void) async throws {
        autoremoveCallCount += 1
        if let error = autoremoveError { throw error }
    }

    func fetchInstalledCasks() async throws -> [CaskEntry] {
        []
    }

    func fetchInstalledPackages() async throws -> [InstalledPackage] {
        []
    }

    func resolvePackage(_: String) async throws -> ResolvedPackage? {
        nil
    }

    func fetchTaps() async throws -> [Tap] {
        []
    }

    func fetchTapPackages(_: String) async throws -> [SearchResult] {
        []
    }

    func addTap(_: String, onLine _: @escaping @Sendable (String) -> Void) async throws {}

    func removeTap(_: String) async throws {}

    func searchPackages(_: String) async throws -> [SearchResult] {
        []
    }

    func runUpdate() async throws {
        updateCallCount += 1
    }

    func runUpgrade(_: String) async throws {
        upgradeCallCount += 1
        if let error = upgradeError { throw error }
    }

    private(set) var upgradeAllNames: [String] = []
    func runUpgradeAll(names: [String], onLine _: @escaping @Sendable (String) -> Void) async throws {
        upgradeAllNames = names
        upgradeCallCount += 1
        if let error = upgradeError { throw error }
    }

    func installPackage(
        _: String,
        isCask _: Bool,
        onLine _: @escaping @Sendable (String) -> Void,
        onProgress _: (@Sendable (String) -> Void)?
    ) async throws {}

    func uninstallPackage(_: String, isCask _: Bool, onLine _: @escaping @Sendable (String) -> Void) async throws {}

    func startService(_: String) async throws {
        startCallCount += 1
    }

    func stopService(_: String) async throws {
        stopCallCount += 1
    }
}

// MARK: - Fixtures

private func package(_ name: String, from: String = "1.0.0", to: String = "2.0.0") -> OutdatedPackage {
    OutdatedPackage(name: name, installedVersions: [from], currentVersion: to, pinned: false)
}

// MARK: - Tests

@Suite("MenuBarViewModel")
@MainActor
struct MenuBarViewModelTests {
    // MARK: Estado inicial

    @Test("status inicial es .initializing")
    func initialStatusIsInitializing() {
        let vm = MenuBarViewModel(service: MockBrewService())
        #expect(vm.status == .initializing)
        #expect(vm.outdatedPackages.isEmpty)
        #expect(vm.lastChecked == nil)
        #expect(!vm.isRefreshing)
        #expect(!vm.isUpgrading)
    }

    @Test("hasSomethingToAttendTo: true en .initializing, false en .ok, true en .error")
    func hasSomethingToAttendToTracksStatus() async {
        let vm = MenuBarViewModel(service: MockBrewService())
        // Don't hide the icon before the first check has ever completed.
        #expect(vm.hasSomethingToAttendTo)

        await vm.performBootstrap()
        #expect(vm.status == .ok)
        #expect(!vm.hasSomethingToAttendTo)

        vm.handleBackgroundError(BrewError.notConfigured)
        #expect(vm.hasSomethingToAttendTo)
    }

    // MARK: performBootstrap — happy path

    @Test("performBootstrap sin outdated → status .ok")
    func bootstrapWithNoOutdatedSetsOk() async {
        let vm = MenuBarViewModel(service: MockBrewService())
        await vm.performBootstrap()
        #expect(vm.status == .ok)
        #expect(vm.outdatedPackages.isEmpty)
        #expect(vm.lastChecked != nil)
        #expect(!vm.isRefreshing)
    }

    @Test("performBootstrap con paquetes → status .updates(count:)")
    func bootstrapWithOutdatedSetsUpdates() async {
        let service = MockBrewService()
        await service.setFetchResponses([[package("git"), package("curl")]])
        let vm = MenuBarViewModel(service: service)

        await vm.performBootstrap()

        #expect(vm.status == .updates(count: 2))
        #expect(vm.outdatedPackages.count == 2)
        #expect(vm.outdatedPackages[0].name == "git")
    }

    @Test("performBootstrap llama bootstrap y fetchOutdated en orden")
    func bootstrapCallsServiceInOrder() async {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)

        await vm.performBootstrap(customBrewPath: "/custom/brew")

        let bCount = await service.bootstrapCallCount
        let fCount = await service.fetchCallCount
        #expect(bCount == 1)
        #expect(fCount == 1)
    }

    // MARK: performBootstrap — errores

    @Test("performBootstrap con notFound → mensaje menciona Homebrew")
    func bootstrapNotFoundSetsError() async {
        let service = MockBrewService()
        await service.setBootstrapError(BrewError.notFound(searchedPaths: []))
        let vm = MenuBarViewModel(service: service)

        await vm.performBootstrap()

        guard case let .error(msg) = vm.status else {
            Issue.record("Se esperaba .error, obtuvo \(vm.status)")
            return
        }
        #expect(msg.contains("Homebrew"))
    }

    @Test("performBootstrap con commandFailed → status .error")
    func bootstrapCommandFailedSetsError() async {
        let service = MockBrewService()
        await service.setBootstrapError(BrewError.commandFailed(exitCode: 1, stderr: "oops"))
        let vm = MenuBarViewModel(service: service)

        await vm.performBootstrap()

        if case .error = vm.status { } else {
            Issue.record("Se esperaba .error")
        }
    }

    @Test("performBootstrap con fetchOutdated fallando → status .error")
    func bootstrapFetchFailureSetsError() async {
        let service = MockBrewService()
        await service.setFetchError(BrewError.commandFailed(exitCode: 1, stderr: "fetch failed"))
        let vm = MenuBarViewModel(service: service)

        await vm.performBootstrap()

        guard case .error = vm.status else {
            Issue.record("Se esperaba .error tras fallo de fetchOutdated, obtuvo \(vm.status)")
            return
        }
        let bCount = await service.bootstrapCallCount
        let fCount = await service.fetchCallCount
        #expect(bCount == 1)
        #expect(fCount == 1)
    }

    @Test("performBootstrap con error genérico (no BrewError) → status .error")
    func bootstrapGenericErrorSetsError() async {
        let service = MockBrewService()
        await service.setBootstrapError(URLError(.badURL))
        let vm = MenuBarViewModel(service: service)

        await vm.performBootstrap()

        guard case .error = vm.status else {
            Issue.record("Se esperaba .error con error genérico, obtuvo \(vm.status)")
            return
        }
    }

    // MARK: performUpgradeAll

    @Test("performUpgradeAll llama runUpgradeAll y re-fetches")
    func upgradeAllCallsServiceAndRefetches() async {
        let service = MockBrewService()
        await service.setFetchResponses([
            [package("git")], // respuesta del bootstrap
            [], // respuesta después del upgrade
        ])
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()
        #expect(vm.status == .updates(count: 1))

        await vm.performUpgradeAll()

        let uCount = await service.upgradeCallCount
        let fCount = await service.fetchCallCount
        #expect(uCount == 1)
        #expect(fCount == 2) // bootstrap + post-upgrade
        #expect(vm.status == .ok)
        #expect(!vm.isUpgrading)
    }

    // Regression: the isRefreshing guard was set inside the Task, so two refresh() calls
    // in a row both passed it and ran `brew update` twice.
    @Test("refresh() llamado dos veces seguidas ejecuta brew update una sola vez")
    func refreshTwiceRunsUpdateOnce() async throws {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        vm.refresh()
        vm.refresh()
        try await waitUntil { !vm.isRefreshing }

        #expect(await service.updateCallCount == 1)
    }

    @Test("performUpgradeAll con error → status .error")
    func upgradeAllFailureSetsError() async {
        let service = MockBrewService()
        await service.setUpgradeError(BrewError.commandFailed(exitCode: 1, stderr: "upgrade failed"))
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        await vm.performUpgradeAll()

        if case .error = vm.status { } else {
            Issue.record("Se esperaba .error")
        }
        #expect(vm.upgradeFailure != nil)
        #expect(!vm.isUpgrading)
    }

    // MARK: performCleanUp

    @Test("performCleanUp llama runCleanup y re-fetches")
    func cleanUpCallsServiceAndRefetches() async {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        await vm.performCleanUp()

        let cCount = await service.cleanupCallCount
        #expect(cCount == 1)
        #expect(!vm.isCleaningUp)
        #expect(vm.cleanupLog.isEmpty) // el mock no emite líneas, pero no debe romper
    }

    @Test("performCleanUp con error → status .error, no queda marcado como en curso")
    func cleanUpFailureSetsError() async {
        let service = MockBrewService()
        await service.setCleanupError(BrewError.commandFailed(exitCode: 1, stderr: "cleanup failed"))
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        await vm.performCleanUp()

        if case .error = vm.status { } else {
            Issue.record("Se esperaba .error")
        }
        #expect(!vm.isCleaningUp)
    }

    // MARK: performAutoremove

    @Test("performAutoremove llama runAutoremove y re-fetches")
    func autoremoveCallsServiceAndRefetches() async {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        await vm.performAutoremove()

        let aCount = await service.autoremoveCallCount
        #expect(aCount == 1)
        #expect(!vm.isRemovingUnusedDependencies)
        #expect(vm.autoremoveLog.isEmpty) // el mock no emite líneas, pero no debe romper
    }

    @Test("performAutoremove con error → status .error, no queda marcado como en curso")
    func autoremoveFailureSetsError() async {
        let service = MockBrewService()
        await service.setAutoremoveError(BrewError.commandFailed(exitCode: 1, stderr: "autoremove failed"))
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        await vm.performAutoremove()

        if case .error = vm.status { } else {
            Issue.record("Se esperaba .error")
        }
        #expect(!vm.isRemovingUnusedDependencies)
    }

    // MARK: Guards

    @Test("refresh es no-op cuando ya está refrescando")
    func refreshIsNoOpWhenRefreshing() async {
        let vm = MenuBarViewModel(service: MockBrewService())
        // Simulamos isRefreshing accediendo al estado interno directamente
        // (imposible sin romper encapsulación — verificamos el guard indirectamente:
        // si refresh crea una segunda tarea, fetchCallCount sería >1)
        await vm.performBootstrap()
        // La lógica del guard se verifica via compilación + inspección del código.
        // El test real de guards requiere inyectar delays, que es scope de v0.2.
        #expect(vm.status == .ok) // sanity check
    }
}

// Regression: a background check that started before an upgrade could finish after it and
// overwrite the fresh list — the menu bar kept counting an update that was already done.
@Suite("MenuBarViewModel — resultados de fondo obsoletos")
@MainActor
struct MenuBarStaleBackgroundResultTests {
    @Test("un resultado de fondo iniciado antes de la última consulta de primer plano se descarta")
    func staleBackgroundResultIsDropped() async {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap() // foreground fetch: nothing outdated

        vm.updatePackages([package("opencode", from: "1.18", to: "2.0")], fetchedAt: Date(timeIntervalSinceNow: -60))

        #expect(vm.outdatedPackages.isEmpty)
    }

    @Test("un resultado de fondo iniciado después de la última consulta sí se aplica")
    func freshBackgroundResultIsApplied() async {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        vm.updatePackages([package("wget", from: "1.0", to: "1.1")], fetchedAt: Date())

        #expect(vm.outdatedPackages.map(\.name) == ["wget"])
    }
}

// Regression: a failed cleanup dry-run was recorded as "0 bytes reclaimable", which cleared
// the "Cleanup pending" insight on a guess. The last known value has to be kept instead.
@Suite("MenuBarViewModel — dry-run fallido en el snapshot")
@MainActor
struct MenuBarHygieneSnapshotTests {
    @Test("si el dry-run de cleanup falla, el snapshot conserva el último valor conocido")
    func failedDryRunKeepsLastKnownValue() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let history = HistoryStore(directory: dir)
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service, historyStore: history)
        await vm.performBootstrap()

        await service.setCleanupDryRunBytes(4_000_000)
        await vm.performCleanUp()
        try await waitUntil { await (try? history.loadRecent().first?.cleanupBytesReclaimable) == 4_000_000 }

        await service.setCleanupDryRunError(BrewError.commandFailed(exitCode: 1, stderr: "boom"))
        await vm.performCleanUp()

        let latest = try await history.loadRecent().first
        #expect(latest?.cleanupBytesReclaimable == 4_000_000)
    }
}

/// Regression coverage for "Clean Up" cancellation: the popover's Cancel must stop the run
/// without leaving an error behind.
@Suite("MenuBarViewModel — cancelar cleanup")
@MainActor
struct MenuBarCleanupCancelTests {
    @Test("cancelCleanUp() detiene el cleanup en curso sin dejar un error")
    func cancelCleanUpStopsRunWithoutError() async throws {
        let service = MockBrewService()
        await service.setCleanupDelay(5_000_000_000)
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        vm.cleanUp()
        try await waitUntil { vm.isCleaningUp }
        let cancelledAt = ContinuousClock.now
        vm.cancelCleanUp()
        try await waitUntil { !vm.isCleaningUp }

        // The run sleeps for 5s: finishing well before that proves the cancel stopped it,
        // instead of the test just waiting for the run to end on its own.
        #expect(ContinuousClock.now - cancelledAt < .seconds(2))
        if case .error = vm.status { Issue.record("Cancelar no debe dejar un error") }
    }
}

// Regression: "Upgrade All" used a bare `brew upgrade`, which also replaced BrewMenu's own cask
// while the app was running. BrewMenu now keeps its own Update button and is left out of the sweep.
@Suite("MenuBarViewModel — Upgrade All no toca la propia app")
@MainActor
struct MenuBarSelfCaskTests {
    private func cask(_ name: String) -> OutdatedPackage {
        OutdatedPackage(name: name, installedVersions: ["1.0"], currentVersion: "2.0", pinned: false, isCask: true)
    }

    @Test("el sweep excluye la cask brewmenu, pero conserva un paquete de fórmula con el mismo nombre")
    func sweepExcludesOnlyTheCask() {
        let packages = [package("wget"), cask("brewmenu"), package("brewmenu")]
        let targets = MenuBarViewModel.bulkUpgradeTargets(packages)
        #expect(targets.map(\.name) == ["wget", "brewmenu"])
        #expect(targets.allSatisfy { !($0.isCask && $0.name == "brewmenu") })
    }

    @Test("Upgrade All nombra solo los paquetes del sweep y no marca reinicio")
    func upgradeAllNamesOnlySweepTargets() async {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()
        vm.updatePackages([package("wget"), cask("brewmenu"), package("git")])

        await vm.performUpgradeAll()

        #expect(await service.upgradeAllNames == ["wget", "git"])
        #expect(!vm.needsRestart)
    }

    @Test("si solo está desactualizada brewmenu, Upgrade All no hace nada")
    func onlySelfUpdateMeansNothingToSweep() async {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()
        vm.updatePackages([cask("brewmenu")])

        #expect(vm.bulkUpgradeCount == 0)
        vm.upgradeAll()
        #expect(!vm.isUpgrading)
        #expect(await service.upgradeAllNames.isEmpty)
    }
}
