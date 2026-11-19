import BrewCore
@testable import BrewMenu
import Foundation
import Testing

/// Regression coverage for the upgrade flow: one upgrade at a time, a Cancel that says what it did,
/// and a failure that goes away once it's been seen.
@Suite("Upgrades — de uno en uno, cancelables y con su fallo a la vista")
@MainActor
struct UpgradeFlowTests {
    private func outdated(_ name: String) -> OutdatedPackage {
        OutdatedPackage(name: name, installedVersions: ["1.0"], currentVersion: "2.0", pinned: false)
    }

    // Regression: Upgrade All only checked for another Upgrade All, started over a single upgrade,
    // and took over its task — the single one could no longer be cancelled.
    @Test("Upgrade All no arranca mientras corre un upgrade individual")
    func upgradeAllWaitsForASingleUpgrade() async throws {
        let service = MockBrewService()
        await service.setFetchResponses([[outdated("wget"), outdated("git")]])
        await service.holdUpgrade()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        vm.upgradePackage("wget")
        try await waitUntil { await service.upgradeCallCount == 1 }
        vm.upgradeAll()
        #expect(!vm.isUpgrading)

        await service.releaseUpgrade()
        try await waitUntil { !vm.isRunningAnyUpgrade }
        #expect(await service.upgradeCallCount == 1)
    }

    // Regression: the log sheet was raised before the call, so a run that never started (a check
    // under way, nothing to upgrade) left an empty sheet saying "Done".
    @Test("Upgrade All dice si arrancó, para no abrir la hoja sobre nada")
    func upgradeAllSaysWhetherItStarted() async {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        // Nothing outdated: nothing to start.
        #expect(!vm.upgradeAll())
        #expect(!vm.isUpgrading)
    }

    @Test("Upgrade All pulsado dos veces seguidas corre una sola vez")
    func upgradeAllTwiceRunsOnce() async throws {
        let service = MockBrewService()
        await service.setFetchResponses([[outdated("wget")]])
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        vm.upgradeAll()
        vm.upgradeAll()
        try await waitUntil { !vm.isRunningAnyUpgrade }

        #expect(await service.upgradeCallCount == 1)
    }

    // Regression: after Cancel the sheet kept saying "Upgrading…" with a Cancel that did nothing,
    // then ended on a green "Done".
    @Test("cancelar un upgrade pasa por 'cancelando' y termina como cancelado")
    func cancelledUpgradeSaysSo() async throws {
        let service = MockBrewService()
        await service.setFetchResponses([[outdated("wget")]])
        await service.holdUpgrade()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        vm.upgradePackage("wget")
        try await waitUntil { await service.upgradeCallCount == 1 }
        vm.cancelUpgrade()
        #expect(vm.upgradePhase == .cancelling)

        await service.releaseUpgrade()
        try await waitUntil { !vm.isRunningAnyUpgrade }
        #expect(vm.upgradePhase == .cancelled)
    }

    // Regression: closing the failed upgrade's sheet left the menu bar icon red until the next check.
    @Test("cerrar la hoja de un upgrade fallido quita también el error del icono")
    func closingTheFailureClearsTheIcon() async {
        let service = MockBrewService()
        await service.setFetchResponses([[outdated("wget")], [outdated("wget")]])
        await service.setUpgradeError(BrewError.commandFailed(exitCode: 1, stderr: "Error: nope"))
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        await vm.performUpgradeAll()
        #expect(vm.upgradePhase == .failed)
        guard case .error = vm.status else {
            Issue.record("se esperaba .error, llegó \(vm.status)")
            return
        }

        vm.clearUpgradeFailure()

        #expect(vm.status == .updates(count: 1))
    }
}
