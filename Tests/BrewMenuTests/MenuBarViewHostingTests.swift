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
        #expect(hosted.labels.contains("\(L("Outdated Packages")), 1"), "labels on screen: \(hosted.labels)")
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

    @Test(
        "con muchos pendientes no repite el contador como insight, y durante un upgrade las demás filas no ofrecen su botón"
    )
    func quietWhileUpgrading() async throws {
        let service = MockBrewService()
        let names = (1 ... 21).map { String(format: "pkg%02d", $0) }
        await service.setFetchResponses([names.map {
            OutdatedPackage(name: $0, installedVersions: ["1.0"], currentVersion: "2.0", pinned: false)
        }])
        await service.holdUpgrade()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        // The app has the insight; the popover leaves it to the header and the list.
        #expect(vm.insights.contains { $0.id == "accumulated-updates" })
        #expect(!vm.popoverInsights.contains { $0.id == "accumulated-updates" })

        let hosted = HostedView(MenuBarView(viewModel: vm, dashboardNav: DashboardNavigation()))
        defer { hosted.close() }
        try await hosted.settle()
        #expect(!hosted.labels.contains(L("Many upgrades accumulated")), "labels: \(hosted.labels)")
        #expect(hosted.labels.contains(L("Upgrade \("pkg02")")), "labels: \(hosted.labels)")

        vm.upgradePackage("pkg01")
        try await waitUntil { await service.upgradeCallCount == 1 }
        try await hosted.settle()
        #expect(!hosted.labels.contains(L("Upgrade \("pkg02")")), "labels: \(hosted.labels)")
        #expect(hosted.labels.contains(L("Upgrading \("pkg01")")), "labels: \(hosted.labels)")

        await service.releaseUpgrade()
        try await waitUntil { !vm.isRunningAnyUpgrade }
    }

    @Test("Services empieza plegado, dice cuántos hay, se despliega y lo recuerda")
    func servicesFoldAndCount() async throws {
        // The fold is remembered in `UserDefaults.brewMenu` (an isolated suite in a test run);
        // start from, and leave, the default so no other run inherits it.
        let key = "menuBar.servicesCollapsed"
        UserDefaults.brewMenu.removeObject(forKey: key)
        defer { UserDefaults.brewMenu.removeObject(forKey: key) }

        let service = MockBrewService()
        await service.setServicesResponse(["cloudflared", "ollama", "postgresql@18"].map {
            ServiceEntry(name: $0, status: .stopped, user: nil, exitCode: nil)
        })
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()
        await vm.refreshServices()

        let hosted = HostedView(MenuBarView(viewModel: vm, dashboardNav: DashboardNavigation()))
        defer { hosted.close() }
        try await hosted.settle()

        // Folded by default: the count shows, the rows don't.
        let header = try #require(hosted.element(labeled: "\(L("Services")), 3"), "labels: \(hosted.labels)")
        #expect(!hosted.labels.contains(L("Start \("ollama")")), "labels: \(hosted.labels)")

        #expect(header.press())
        try await hosted.settle(.milliseconds(400))
        #expect(hosted.labels.contains(L("Start \("ollama")")), "labels: \(hosted.labels)")
        #expect(UserDefaults.brewMenu.object(forKey: key) as? Bool == false)
    }
}
