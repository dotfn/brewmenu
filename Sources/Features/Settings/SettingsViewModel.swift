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
    @ObservationIgnored private var savedBrewPath: String?
    @ObservationIgnored private var appliedCheckInterval: AppSettings.CheckInterval?
    /// Guards `settings`'s didSet from scheduling a save while `load()` is assigning it —
    /// without this, every launch would immediately re-save whatever was just read back.
    @ObservationIgnored private var isLoading = false
    /// Debounced, cancellable save — same cancel-and-reassign `Task` idiom already used by
    /// `DashboardViewModel.searchTask`/`installTask`. Lets `SettingsViewModel` own its own
    /// persistence instead of relying on a caller (e.g. a view's `.onChange`) to save on
    /// its behalf, which only ever worked because there happened to be exactly one such
    /// caller.
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var settings: AppSettings = .init() {
        didSet {
            guard !isLoading, oldValue != settings else { return }
            scheduleSave()
        }
    }

    var saveError: String?

    init(store: SettingsStore, checker: StatusChecker, notifier: BrewNotifier, historyStore: HistoryStore? = nil) {
        self.store = store
        self.checker = checker
        self.notifier = notifier
        self.historyStore = historyStore
    }

    func load() async {
        isLoading = true
        settings = await store.settings
        savedBrewPath = settings.customBrewPath
        appliedCheckInterval = settings.checkInterval
        isLoading = false
    }

    /// Whether the typed Homebrew path points at something runnable (empty = auto-detect).
    var brewPathIsValid: Bool {
        guard let path = settings.customBrewPath else { return true }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Persists `settings` immediately — cancels any pending debounced save scheduled by
    /// `scheduleSave()` first, so an explicit save (e.g. from `resetAllData()`) is never
    /// redundantly repeated a moment later by a debounce that was already in flight.
    func save() async {
        saveTask?.cancel()
        saveTask = nil
        let newPath = settings.customBrewPath
        let brewPathChanged = newPath != savedBrewPath
        do {
            try await store.save(settings)
            // Restarting the hourly timer on every save would reset it for unrelated edits.
            if settings.checkInterval != appliedCheckInterval {
                appliedCheckInterval = settings.checkInterval
                await checker.setInterval(settings.checkInterval.statusCheckerInterval)
            }
            applyLaunchAtLogin(settings.launchAtLogin)
            await notifier.configure(
                notifyOnUpdates: settings.notifyOnUpdates,
                notifyOnUpgradeFailure: settings.notifyOnUpgradeFailure,
                notifyOnDoctorWarnings: settings.notifyOnDoctorWarnings,
                notifyOnCriticalInsights: settings.notifyOnCriticalInsights
            )
            saveError = nil
            // Only a runnable path triggers a bootstrap — a half-typed one would surface
            // "Homebrew not found" on every pause. It's saved, and flagged inline.
            if brewPathChanged, brewPathIsValid {
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
        // Caches and logs live outside Application Support now; "reset" must still clear them.
        for outside in [FileManager.brewMenuCachesDirectory, FileManager.brewMenuLogsDirectory] {
            try? FileManager.default.removeItem(at: outside)
        }
        await historyStore?.reset()
        // hasCompletedOnboarding's single source of truth is UserDefaults (see
        // OnboardingViewModel) — settings.json doesn't carry it, so it has to be
        // cleared here explicitly for "Reset all data" to actually re-trigger onboarding.
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        settings = AppSettings()
        await save()
    }

    // MARK: - Private

    /// Debounces bursts of `settings` writes (a Picker drag, several toggles flipped in a
    /// row) into a single save, ~400ms after the last change — instead of one disk write
    /// per keystroke/click.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            // SMAppService only works for an app installed in /Applications; anything else
            // lands here. Say so, and show what's actually registered instead of the toggle.
            // (Setting it to the real state can't loop: a matching state never re-fails.)
            saveError = L("Couldn't change Launch at Login: \(error.localizedDescription)")
            settings.launchAtLogin = service.status == .enabled
        }
    }
}
