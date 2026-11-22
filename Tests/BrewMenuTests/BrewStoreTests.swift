import BrewCore
@testable import BrewMenu
import Foundation
import Testing

/// Regression coverage for the state that used to live in several places at once (the menu bar, the
/// Dashboard, StatusChecker, history) and drift apart. Each test changes it from one side and reads
/// it from another.
@Suite("BrewStore — una sola copia del estado de brew")
@MainActor
struct BrewStoreTests {
    private func installed(_ name: String, version: String) -> InstalledPackage {
        InstalledPackage(
            name: name, tap: "homebrew/core", desc: nil, homepage: nil, version: version,
            isCask: false, pinned: false, outdated: false, deprecated: false,
            deprecationReason: nil, disabled: false, disableReason: nil
        )
    }

    private func outdated(_ name: String) -> OutdatedPackage {
        OutdatedPackage(name: name, installedVersions: ["1.0"], currentVersion: "2.0", pinned: false)
    }

    private func isolatedHistory() -> HistoryStore {
        HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test("un upgrade desde el menú refresca la lista de instalados que ve el Dashboard")
    func menuUpgradeRefreshesDashboardInstalledList() async {
        let service = MockBrewService()
        await service.setInstalledResponse([installed("git", version: "1.0")])
        let store = BrewStore(service: service)
        let menuBar = MenuBarViewModel(service: service, store: store)
        let dashboard = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), store: store)
        await dashboard.refreshInstalled()

        await service.setInstalledResponse([installed("git", version: "2.0")])
        await menuBar.performUpgradeAll()

        #expect(dashboard.installedPackages.map(\.version) == ["2.0"])
    }

    @Test("un uninstall desde el Dashboard saca el paquete de los desactualizados del menú")
    func dashboardUninstallRefreshesMenuOutdatedList() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([installed("wget", version: "1.0")])
        let store = BrewStore(service: service)
        let menuBar = MenuBarViewModel(service: service, store: store)
        let dashboard = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), store: store)
        await dashboard.refreshInstalled()
        store.applyOutdated([outdated("wget")], startedAt: Date(timeIntervalSinceNow: -1))
        #expect(menuBar.status == .updates(count: 1))

        await dashboard.uninstall(name: "wget", isCask: false)

        #expect(menuBar.outdatedPackages.isEmpty)
        #expect(menuBar.status == .ok)
    }

    @Test("un resultado pedido antes del que ya se muestra se descarta, venga de donde venga")
    func olderResultNeverOverwritesNewerOne() {
        let store = BrewStore(service: MockBrewService())
        store.applyOutdated([outdated("wget")], startedAt: Date())

        let applied = store.applyOutdated([outdated("old")], startedAt: Date(timeIntervalSinceNow: -60))

        #expect(!applied)
        #expect(store.outdated.map(\.name) == ["wget"])
    }

    // Regression: the live state was put on top of a snapshot that already held it, so the
    // comparison between the last two checks saw no change, and the insight vanished as soon as
    // the popover polled services.
    @Test("'Service down' sigue visible después de volver a leer los servicios")
    func serviceDownSurvivesAServicesRefresh() async throws {
        let history = isolatedHistory()
        try await history.save(Snapshot(
            timestamp: Date(timeIntervalSinceNow: -3600),
            outdatedPackages: [],
            doctorWarnings: [],
            services: [ServiceEntry(name: "postgresql", status: .started, user: nil, exitCode: nil)]
        ))
        let service = MockBrewService()
        await service.setServicesResponse([ServiceEntry(name: "postgresql", status: .stopped, user: nil, exitCode: 1)])
        let store = BrewStore(service: service, historyStore: history)

        await store.runScheduledCheck(BrewStore.CheckPlan())
        #expect(store.insights.contains { $0.id == "service-down" })

        await store.refresh([.services])
        #expect(store.insights.contains { $0.id == "service-down" })
    }

    // Regression: the dry-run results only came from the first scheduled check, an hour after
    // launch, so their insights were missing until then.
    @Test("al arrancar, los dry-runs salen del último snapshot hasta que se vuelvan a medir")
    func restoreFromHistoryFillsDryRuns() async throws {
        let history = isolatedHistory()
        try await history.save(Snapshot(outdatedPackages: [], doctorWarnings: [], autoremovableFormulae: ["libfoo"]))
        let menuBar = MenuBarViewModel(service: MockBrewService(), historyStore: history)

        await menuBar.performBootstrap()

        #expect(menuBar.autoremovableFormulae == ["libfoo"])
        #expect(menuBar.insights.contains { $0.id == "unused-dependencies" })
    }

    @Test("el error de una acción se ve en el menú y lo limpia la siguiente lista buena")
    func actionErrorClearsOnNextGoodList() async {
        let service = MockBrewService()
        let menuBar = MenuBarViewModel(service: service)
        await menuBar.performBootstrap()
        await service.setUpgradeError(BrewError.commandFailed(exitCode: 1, stderr: "boom"))
        await menuBar.performUpgradeAll()
        guard case .error = menuBar.status else {
            Issue.record("Se esperaba .error, obtuvo \(menuBar.status)")
            return
        }

        await menuBar.store.refresh([.outdated])

        #expect(menuBar.status == .ok)
    }

    @Test("quitar un tap olvida la lista de paquetes que se había leído de él")
    func removingTapForgetsItsPackages() async {
        let service = MockBrewServiceForDashboard()
        await service.setTapPackagesResponse("a/b", [SearchResult(name: "a/b/tool", isCask: false)])
        let dashboard = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService())
        await dashboard.loadTapPackages(for: "a/b")
        #expect(dashboard.tapPackages["a/b"]?.count == 1)

        await dashboard.removeTap("a/b")

        #expect(dashboard.tapPackages["a/b"] == nil)
    }
}

@Suite("BrewStore — refresco en curso compartido")
@MainActor
struct BrewStoreRefreshingTests {
    // Regression: the menu bar and the Dashboard each had their own `isRefreshing`, and neither
    // showed a check the other one (or the timer) had started.
    @Test("un chequeo iniciado desde el Dashboard se ve como refresco en curso en el menú")
    func dashboardCheckShowsInMenuBar() async throws {
        let service = MockBrewService()
        await service.holdUpdate()
        let store = BrewStore(service: service)
        let menuBar = MenuBarViewModel(service: service, store: store)

        let check = Task { await store.checkForUpdates() }
        try await waitUntil { await service.updateCallCount == 1 }

        #expect(menuBar.isRefreshing)
        await service.releaseUpdate()
        _ = await check.value
        #expect(!menuBar.isRefreshing)
    }

    // Regression: any caller's cancel cancelled the shared update — a Settings interval change
    // (restarting the timer) killed the `brew update` an upgrade was waiting on.
    @Test("cancelar a quien espera un brew update compartido no lo corta para los demás")
    func cancellingOneWaiterKeepsTheSharedUpdate() async throws {
        let service = MockBrewService()
        await service.holdUpdate()
        let store = BrewStore(service: service)
        let joined = Flag()

        let scheduled = Task { await store.checkForUpdates() }
        try await waitUntil { await service.updateCallCount == 1 }
        let upgrade = Task { await store.syncDatabaseIfStale { joined.isSet = true } }
        try await waitUntil { joined.isSet }

        scheduled.cancel()
        _ = await scheduled.value // stops waiting at once, with the update still held
        await service.releaseUpdate()
        #expect(await upgrade.value)

        #expect(await service.updateCallCount == 1)
        #expect(await !service.updateWasCancelled)
        #expect(store.databaseSyncedAt != nil)
    }

    @Test("si todos dejan de esperar, el brew update sí se cancela")
    func lastWaiterLeavingCancelsTheUpdate() async throws {
        let service = MockBrewService()
        await service.holdUpdate()
        let store = BrewStore(service: service)

        let only = Task { await store.checkForUpdates() }
        try await waitUntil { await service.updateCallCount == 1 }
        only.cancel()
        _ = await only.value
        await service.releaseUpdate()

        try await waitUntil { await service.updateWasCancelled }
    }
}

@Suite("BrewStore — brew update tras una cancelación")
@MainActor
struct BrewStoreUpdateAfterCancelTests {
    // Regression: joining an update its only waiter had just cancelled (it takes brew a moment to
    // stop) resumed the new caller as if the database had been updated.
    @Test("quien se une a un brew update que se estaba cancelando lanza otro")
    func joiningACancelledUpdateRunsAnother() async throws {
        let service = MockBrewService()
        await service.holdUpdate()
        let store = BrewStore(service: service)

        let leaving = Task { await store.checkForUpdates() }
        try await waitUntil { await service.updateCallCount == 1 }
        leaving.cancel()
        _ = await leaving.value
        let joined = Flag()
        let upgrade = Task { await store.syncDatabaseIfStale { joined.isSet = true } }
        try await waitUntil { joined.isSet }
        await service.releaseUpdate()

        #expect(await upgrade.value)
        #expect(await service.updateCallCount == 2)
    }

    @Test("un llamador ya cancelado no arranca ningún brew update")
    func cancelledCallerStartsNothing() async {
        let service = MockBrewService()
        let store = BrewStore(service: service)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.checkForUpdates()
        }
        _ = await cancelled.value

        #expect(await service.updateCallCount == 0)
    }
}

@MainActor
private final class Flag {
    var isSet = false
}

/// The package page opens on top of the list it came from (it used to be a modal sheet), and the
/// detail column's path has to stay consistent with the sidebar.
@Suite("DashboardNavigation — páginas sobre la sección")
@MainActor
struct DashboardNavigationTests {
    private let target = PackageDetailTarget(name: "wget", isCask: false, tap: "homebrew/core")

    @Test("abrir un paquete lo apila sobre la sección actual")
    func openPackagePushes() {
        let navigation = DashboardNavigation()
        navigation.selectedSection = .apps

        navigation.openPackage(target)

        #expect(navigation.path == [.package(target)])
        #expect(navigation.selectedSection == .apps)
    }

    @Test("cambiar de sección vuelve al principio de la nueva")
    func changingSectionResetsThePath() {
        let navigation = DashboardNavigation()
        navigation.openPackage(target)

        navigation.selectedSection = .installed

        #expect(navigation.path.isEmpty)
    }

    @Test("una colección se abre sobre Descubrir, desde ahí o desde otra sección")
    func openCollectionOnDiscover() {
        let navigation = DashboardNavigation()
        let pack = InstallPack(id: "x", title: "X", subtitle: "", systemImage: "star", formulae: ["git"], casks: [])

        navigation.openCollection(pack)
        #expect(navigation.selectedSection == .home)
        #expect(navigation.path == [.collection(pack)])

        navigation.selectedSection = .installed
        navigation.openCollection(pack)
        #expect(navigation.selectedSection == .home)
        #expect(navigation.path == [.collection(pack)])
    }

    @Test("la página carga el detalle del paquete con su tap")
    func selectPackageKeepsTheTap() {
        let vm = DashboardViewModel(service: MockBrewServiceForDashboard(), apiClient: MockHomebrewAPIService())

        vm.selectPackage(name: "orca", isCask: true, tap: "stablyai/orca")

        #expect(vm.selectedPackageDetailTarget == PackageDetailTarget(name: "orca", isCask: true, tap: "stablyai/orca"))
    }
}
