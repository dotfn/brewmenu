import BrewCore
@testable import BrewMenu
import Foundation
import SwiftUI
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

@MainActor
@Suite("Fila de paquete desactualizado: instalada → disponible")
struct PackageRowVersionTests {
    private func package(_ installed: [String], _ available: String) -> OutdatedPackage {
        OutdatedPackage(name: "gh", installedVersions: installed, currentVersion: available, pinned: false)
    }

    /// What brew says is installed and available, and what the row should show.
    struct VersionCase: CustomTestStringConvertible {
        let installed: [String]
        let available: String
        let from: String?
        let to: String

        init(_ installed: [String], _ available: String, shows from: String?, _ to: String) {
            self.installed = installed
            self.available = available
            self.from = from
            self.to = to
        }

        var testDescription: String {
            "\(installed) → \(available)"
        }
    }

    @Test("muestra de qué versión a cuál, sin builds ni hashes", arguments: [
        VersionCase(["2.40.1"], "2.41.0", shows: "2.40.1", "2.41.0"),
        // Casks: build number or commit after a comma.
        VersionCase(["1.4.0,5281842794987520"], "1.5.14,5302690847260672", shows: "1.4.0", "1.5.14"),
        VersionCase(
            ["3.27.12,df132ffba90dfc15a12e6b8f020ba4e5d026c4be"],
            "3.31.15,3eb8c13390837371c7c2f2013dc57fdbc802c753",
            shows: "3.27.12",
            "3.31.15"
        ),
        // A short commit hash at the end.
        VersionCase(["2026.10.22-27dcf5f"], "2026.11.22-e9042b2", shows: "2026.10.22", "2026.11.22"),
        // Not hashes: a revision, a prerelease.
        VersionCase(["1.17.0_1"], "1.17.0_2", shows: "1.17.0_1", "1.17.0_2"),
        VersionCase(["2.0.0-beta1"], "2.0.0-beta2", shows: "2.0.0-beta1", "2.0.0-beta2"),
        // Only the build changed: the full versions, or it would read "1.0 → 1.0".
        VersionCase(["1.0,100"], "1.0,200", shows: "1.0,100", "1.0,200"),
        // Several kegs: the newest is the one in use.
        VersionCase(["3.132", "3.133"], "3.134", shows: "3.133", "3.134"),
        VersionCase([], "2.41.0", shows: nil, "2.41.0"),
    ])
    func versions(_ example: VersionCase) {
        let versions = PackageRow.Versions(package(example.installed, example.available))
        #expect(versions.from == example.from)
        #expect(versions.to == example.to)
        #expect(versions.full == (example.installed.last.map { "\($0) → \(example.available)" } ?? example.available))
    }

    @Test("dos versiones largas no parten la fila en dos líneas")
    func longVersionsKeepOneLine() {
        func height(_ pkg: OutdatedPackage) -> CGFloat {
            NSHostingView(rootView: PackageRow(package: pkg, isUpgrading: false, onUpgrade: {}).frame(width: 340))
                .fittingSize.height
        }
        let long = package(["131.0.6778.86,8a3f2c1d"], "131.0.6778.109,9b4e3d2f")
        #expect(height(long) == height(package(["1.0"], "2.0")))
    }
}
