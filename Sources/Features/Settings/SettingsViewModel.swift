import Foundation
import ServiceManagement

@MainActor
@Observable
final class SettingsViewModel {
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let checker: StatusChecker
    @ObservationIgnored private let notifier: BrewNotifier

    var settings: AppSettings = AppSettings()
    var saveError: String? = nil

    init(store: SettingsStore, checker: StatusChecker, notifier: BrewNotifier) {
        self.store = store
        self.checker = checker
        self.notifier = notifier
    }

    func load() async {
        settings = await store.settings
    }

    func save() async {
        do {
            try await store.save(settings)
            await checker.setInterval(settings.checkInterval.statusCheckerInterval)
            applyLaunchAtLogin(settings.launchAtLogin)
            await notifier.configure(
                notifyOnUpdates: settings.notifyOnUpdates,
                notifyOnUpgradeFailure: settings.notifyOnUpgradeFailure,
                notifyOnDoctorWarnings: settings.notifyOnDoctorWarnings,
                notifyOnCriticalInsights: settings.notifyOnCriticalInsights
            )
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    func resetAllData() async {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = appSupport.appendingPathComponent("BrewMenu", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        settings = AppSettings()
        await save()
    }

    // MARK: - Private

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            // SMAppService requires the app to be installed in /Applications to work.
            // During development this is expected to fail — not surfaced to the user.
        }
    }
}
