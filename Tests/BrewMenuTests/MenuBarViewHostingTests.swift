import BrewCore
@testable import BrewMenu
import Foundation
import Testing

/// The popover itself, mounted in-process (see `HostedView`), instead of only its view model.
@MainActor
@Suite("MenuBarView montada", .serialized)
struct MenuBarViewHostingTests {
    @Test("el popover muestra el botón de upgrade de cada paquete desactualizado")
    func listsTheOutdatedPackage() async throws {
        let service = MockBrewService()
        await service.setFetchResponses([[
            OutdatedPackage(name: "wget", installedVersions: ["1.0"], currentVersion: "2.0", pinned: false),
        ]])
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        let hosted = HostedView(MenuBarView(viewModel: vm, dashboardNav: DashboardNavigation()))
        defer { hosted.close() }
        try await hosted.settle()

        let label = L("Upgrade \("wget")")
        #expect(hosted.element(labeled: label) != nil, "labels on screen: \(hosted.labels)")
    }

    @Test("pulsar el botón de una fila actualiza ese paquete")
    func pressingTheRowButtonUpgrades() async throws {
        let service = MockBrewService()
        await service.setFetchResponses([[
            OutdatedPackage(name: "wget", installedVersions: ["1.0"], currentVersion: "2.0", pinned: false),
        ]])
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        let hosted = HostedView(MenuBarView(viewModel: vm, dashboardNav: DashboardNavigation()))
        defer { hosted.close() }
        try await hosted.settle()

        let button = try #require(hosted.element(labeled: L("Upgrade \("wget")")), "labels: \(hosted.labels)")
        #expect(button.press())
        try await waitUntil { await service.upgradeCallCount == 1 }
    }
}
