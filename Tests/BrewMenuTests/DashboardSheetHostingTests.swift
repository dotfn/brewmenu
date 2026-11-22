import BrewCore
@testable import BrewMenu
import Foundation
import SwiftUI
import Testing

/// The Dashboard's sheets, opened from the real `DashboardView`: what they read from the
/// environment has to reach them there, not only in a test that hands it over.
@MainActor
@Suite("Hojas del Dashboard montadas", .serialized)
struct DashboardSheetHostingTests {
    private func dashboard(_ menuBar: MenuBarViewModel, _ dashboard: DashboardViewModel,
                           _ navigation: DashboardNavigation) throws -> some View
    {
        let defaults = try #require(UserDefaults(suiteName: "DashboardSheetHostingTests.\(UUID().uuidString)"))
        let settings = SettingsViewModel(
            store: SettingsStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)),
            checker: StatusChecker(store: menuBar.store),
            notifier: BrewNotifier(),
            historyStore: nil,
            defaults: defaults,
            isLaunchAtLoginEnabled: { false }
        )
        return DashboardView(
            viewModel: menuBar,
            settingsViewModel: settings,
            dashboardViewModel: dashboard,
            navigation: navigation
        )
    }

    /// Regression: the sheet's package icon reads `DashboardViewModel` from the environment, which a
    /// sheet doesn't get from the `.environment` its presenter applies below it — the app crashed
    /// the moment an upgrade started.
    @Test("la hoja de upgrade se abre con el ícono del paquete, sin romper la app")
    func upgradeSheetOpens() async throws {
        let service = MockBrewService()
        await service.setFetchResponses([[
            OutdatedPackage(name: "t3-code", installedVersions: ["0.1.8"], currentVersion: "0.1.11", pinned: false),
        ]])
        await service.holdUpgrade()
        let menuBar = MenuBarViewModel(service: service)
        await menuBar.performBootstrap()
        let dashboardViewModel = DashboardViewModel(
            service: MockBrewServiceForDashboard(),
            apiClient: MockHomebrewAPIService(),
            store: menuBar.store
        )
        let navigation = DashboardNavigation()
        let hosted = try HostedView(
            dashboard(menuBar, dashboardViewModel, navigation),
            size: CGSize(width: 900, height: 600)
        )
        defer { hosted.close() }
        try await hosted.settle()

        #expect(menuBar.upgradePackage("t3-code"))
        navigation.showsUpgradeLog = true
        try await waitUntil { await service.upgradeCallCount == 1 }
        try await hosted.settle(.milliseconds(400))

        // The sheet is a window of its own; its title says the package, from the real sheet.
        let sheet = try #require(Self.sheet(besides: hosted.window), "no sheet on the Dashboard")
        let titles = sheet.contentView.map(Self.labels(under:)) ?? []
        #expect(titles.contains(L("Upgrading \("t3-code")")), "labels: \(titles)")

        await service.releaseUpgrade()
        try await waitUntil { !menuBar.isRunningAnyUpgrade }
    }

    @Test("la hoja de instalación también")
    func installSheetOpens() async throws {
        let menuBar = MenuBarViewModel(service: MockBrewService())
        let service = MockBrewServiceForDashboard()
        await service.setInstallDelay(3_000_000_000)
        let dashboardViewModel = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService())
        let hosted = try HostedView(
            dashboard(menuBar, dashboardViewModel, DashboardNavigation()),
            size: CGSize(width: 900, height: 600)
        )
        defer { hosted.close() }
        try await hosted.settle()

        dashboardViewModel.installSingle(name: "wget", isCask: false)
        try await waitUntil { await service.installCalls.count == 1 }
        try await hosted.settle(.milliseconds(400))

        let sheet = try #require(Self.sheet(besides: hosted.window), "no sheet on the Dashboard")
        let titles = sheet.contentView.map(Self.labels(under:)) ?? []
        #expect(titles.contains(L("Installing \("wget")")), "labels: \(titles)")
        dashboardViewModel.cancelInstall()
    }

    /// SwiftUI puts a sheet in a window of its own; never shown, the test's window doesn't get it
    /// attached, so it's found by kind — the newest, as an earlier test's can still be around.
    private static func sheet(besides window: NSWindow) -> NSWindow? {
        NSApplication.shared.windows.last { $0 !== window && "\(type(of: $0))".contains("Sheet") }
    }

    private static func labels(under view: NSView) -> [String] {
        var found: [String] = []
        func visit(_ object: NSObject) {
            let element = HostedElement(object: object)
            if let label = element.label ?? element.value { found.append(label) }
            (object.value(forKey: "accessibilityChildren") as? [NSObject] ?? []).forEach(visit)
        }
        visit(view)
        return found
    }
}
