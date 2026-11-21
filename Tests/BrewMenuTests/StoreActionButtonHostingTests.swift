import BrewCore
@testable import BrewMenu
import Foundation
import SwiftUI
import Testing

/// The action pill, mounted in-process (see `HostedView`): one action per package state.
@MainActor
@Suite("StoreActionButton montado", .serialized)
struct StoreActionButtonHostingTests {
    private func installed(_ name: String) -> InstalledPackage {
        InstalledPackage(
            name: name, tap: "homebrew/core", desc: nil, homepage: nil, version: "1.0.0",
            isCask: false, pinned: false, outdated: false, deprecated: false,
            deprecationReason: nil, disabled: false, disableReason: nil, runtimeDependencyNames: []
        )
    }

    @Test("sin instalar ofrece Get, instalado Uninstall, desactualizado Update — una sola acción cada uno")
    func oneActionPerState() async throws {
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([installed("jq"), installed("git")])
        let dashboard = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService())
        await dashboard.refresh()
        dashboard.store.applyOutdated([
            OutdatedPackage(name: "git", installedVersions: ["1.0"], currentVersion: "2.0", pinned: false),
        ])

        let hosted = HostedView(
            VStack {
                StoreActionButton(name: "wget", isCask: false)
                StoreActionButton(name: "jq", isCask: false)
                StoreActionButton(name: "git", isCask: false)
            }
            .environment(dashboard)
            .environment(MenuBarViewModel(service: MockBrewService()))
            .environment(DashboardNavigation())
        )
        defer { hosted.close() }
        try await hosted.settle()

        let labels = hosted.labels
        #expect(labels.contains(L("Install \("wget")")), "labels: \(labels)")
        #expect(labels.contains(L("Uninstall \("jq")")), "labels: \(labels)")
        #expect(labels.contains(L("Update \("git")")), "labels: \(labels)")
        // No row offers a second action: the old split button put Uninstall behind Update too.
        #expect(!labels.contains(L("Uninstall \("git")")), "labels: \(labels)")
        #expect(!labels.contains(L("Install \("jq")")), "labels: \(labels)")
    }
}
