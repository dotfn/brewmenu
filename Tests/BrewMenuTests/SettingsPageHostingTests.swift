import BrewCore
@testable import BrewMenu
import Foundation
import SwiftUI
import Testing

/// The single Settings page, mounted in-process (see `HostedView`).
@MainActor
@Suite("SettingsPage montada", .serialized)
struct SettingsPageHostingTests {
    @Test("una sola página tiene lo que antes estaba en General, Notifications y About")
    func everySettingOnOnePage() async throws {
        let defaults = try #require(UserDefaults(suiteName: "SettingsPageHostingTests.\(UUID().uuidString)"))
        let viewModel = SettingsViewModel(
            store: SettingsStore(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            ),
            checker: StatusChecker(store: BrewStore(service: MockBrewService())),
            notifier: BrewNotifier(),
            historyStore: nil,
            defaults: defaults,
            isLaunchAtLoginEnabled: { false }
        )
        // Tall enough that the grouped form lays out every section, not just the first screenful.
        let hosted = HostedView(SettingsPage(viewModel: viewModel), size: CGSize(width: 700, height: 1600))
        defer { hosted.close() }
        try await hosted.settle()

        let labels = hosted.labels
        for text in [
            L("Open at login"), // was General
            L("Notify on new upgrades"), // was Notifications
            L("Star on GitHub"), // was About
            "Nicolas Jimenez", // the developer
            "dotfn", // the developer's brand, as VoiceOver reads "●fn"
            L("Reset all data"),
        ] {
            #expect(labels.contains(text), "missing \(text) — labels: \(labels)")
        }
    }

    @Test("la barra lateral tiene una sola entrada de ajustes")
    func oneSettingsDestination() {
        #expect(DashboardSection.settings.title == L("Settings"))
        #expect(!DashboardSection.mainSections.contains(.settings))
        #expect(!DashboardSection.toolSections.contains(.settings))
    }
}
