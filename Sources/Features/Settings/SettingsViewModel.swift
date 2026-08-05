import Foundation
import ServiceManagement

@MainActor
@Observable
final class SettingsViewModel {
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let checker: StatusChecker
    @ObservationIgnored private let notifier: BrewNotifier
    @ObservationIgnored private let historyStore: HistoryStore?
    @ObservationIgnored var onBrewPathChanged: (@Sendable (String?) -> Void)?
    @ObservationIgnored private var savedBrewPath: String? = nil

    var settings: AppSettings = AppSettings()
    var saveError: String? = nil

    init(store: SettingsStore, checker: StatusChecker, notifier: BrewNotifier, historyStore: HistoryStore? = nil) {
        self.store = store
        self.checker = checker
        self.notifier = notifier
        self.historyStore = historyStore
    }

    func load() async {
        settings = await store.settings
        savedBrewPath = settings.customBrewPath
    }

    func save() async {
        let newPath = settings.customBrewPath
        let brewPathChanged = newPath != savedBrewPath
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
            if brewPathChanged {
                savedBrewPath = newPath
                onBrewPathChanged?(newPath)
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    func resetAllData() async {
        let dir = FileManager.brewMenuSupportDirectory
        let snapshotsDir = dir.appendingPathComponent("snapshots", isDirectory: true)
        // Everything except snapshots/, which HistoryStore owns and resets itself
        // below — deleting it directly here could race an in-flight save, and
        // HistoryStore only creates its directory once (at init), so a delete that
        // bypasses it would silently break snapshot persistence for the rest of
        // this app session.
        if let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in contents where url != snapshotsDir {
                try? FileManager.default.removeItem(at: url)
            }
        }
        await historyStore?.reset()
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
