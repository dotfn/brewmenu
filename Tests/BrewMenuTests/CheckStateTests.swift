import BrewCore
@testable import BrewMenu
import Foundation
import Testing

/// Regression coverage for Dashboard pages that read as an all-clear when nothing had been checked,
/// or when the check failed, and for failures that only ever showed in the popover.
@Suite("Dashboard — sin 'todo bien' que no se ha comprobado")
@MainActor
struct CheckStateTests {
    private let outdatedWget = OutdatedPackage(
        name: "wget", installedVersions: ["1.0"], currentVersion: "2.0", pinned: false
    )

    @Test("Updates: antes de la primera comprobación no dice 'al día'")
    func updatesBeforeTheFirstCheck() {
        let vm = MenuBarViewModel(service: MockBrewService())

        #expect(vm.updatesPage == .notChecked)
    }

    @Test("Updates: si Homebrew no aparece al arrancar, la página dice por qué")
    func updatesAfterAFailedBootstrap() async {
        let service = MockBrewService()
        await service.setBootstrapError(BrewError.notFound(searchedPaths: []))
        let vm = MenuBarViewModel(service: service)

        await vm.performBootstrap()

        guard case .failed = vm.updatesPage else {
            Issue.record("se esperaba .failed, llegó \(vm.updatesPage)")
            return
        }
    }

    @Test("Updates: una comprobación fallida deja la lista anterior y muestra el fallo")
    func failedRecheckKeepsTheList() async throws {
        let service = MockBrewService()
        await service.setFetchResponses([[outdatedWget]])
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()
        #expect(vm.updatesPage == .checked)

        await service.setFetchError(BrewError.timedOut(command: "brew outdated", seconds: 120))
        vm.refresh()
        try await waitUntil { !vm.isRefreshing }

        #expect(vm.updatesPage == .checked)
        #expect(vm.outdatedFailure != nil)
        #expect(vm.outdatedPackages.map(\.name) == ["wget"])
    }

    @Test("Services: un arranque fallido se ve en el Dashboard, y el siguiente que funciona lo quita")
    func serviceActionFailureShowsAndClears() async throws {
        let service = MockBrewService()
        await service.setStartServiceError(BrewError.commandFailed(exitCode: 1, stderr: "Error: nope"))
        let vm = MenuBarViewModel(service: service)

        vm.startService("redis")
        try await waitUntil { vm.togglingServices.isEmpty && vm.serviceActionFailure != nil }

        await service.setStartServiceError(nil)
        vm.startService("redis")
        try await waitUntil { vm.togglingServices.isEmpty && vm.serviceActionFailure == nil }
    }

    @Test("Clean Up fallido se ve en Insights, no solo en el popover")
    func maintenanceFailureShows() async {
        let service = MockBrewService()
        await service.setCleanupError(BrewError.commandFailed(exitCode: 1, stderr: "Error: nope"))
        let vm = MenuBarViewModel(service: service)

        await vm.performCleanUp()

        #expect(vm.maintenanceFailure != nil)
    }
}
