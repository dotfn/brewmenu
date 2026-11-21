import BrewCore
@testable import BrewMenu
import Foundation
import SwiftUI
import Testing

/// A package's page, mounted in-process (see `HostedView`).
@MainActor
@Suite("PackageDetailView montada", .serialized)
struct PackageDetailHostingTests {
    @Test("un paquete desactualizado dice qué versión hay y cuál llega, y deja actualizar o desinstalar")
    func outdatedPackagePage() async throws {
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([InstalledPackage(
            name: "git", tap: "homebrew/core", desc: nil, homepage: nil, version: "2.40.0",
            isCask: false, pinned: false, outdated: true, deprecated: false,
            deprecationReason: nil, disabled: false, disableReason: nil, runtimeDependencyNames: []
        )])
        let dashboard = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService())
        await dashboard.refresh()
        dashboard.store.applyOutdated([
            OutdatedPackage(name: "git", installedVersions: ["2.40.0"], currentVersion: "2.47.1", pinned: false),
        ])

        let hosted = HostedView(
            PackageDetailView(
                target: PackageDetailTarget(name: "git", isCask: false, tap: "homebrew/core"),
                dashboardViewModel: dashboard
            )
            .environment(dashboard)
            .environment(MenuBarViewModel(service: MockBrewService()))
            .environment(DashboardNavigation()),
            size: CGSize(width: 900, height: 900)
        )
        defer { hosted.close() }
        try await hosted.settle()

        let labels = hosted.labels
        let status = [L("Command-line tool"), L("Installed \("2.40.0")"), L("\("2.47.1") available")]
            .joined(separator: " · ")
        #expect(labels.contains(status), "labels: \(labels)")
        #expect(labels.contains(L("Update \("git")")), "labels: \(labels)")
        #expect(labels.contains(L("Uninstall \("git")")), "labels: \(labels)")
        #expect(labels.contains("$ brew upgrade git"), "labels: \(labels)")
    }
}
