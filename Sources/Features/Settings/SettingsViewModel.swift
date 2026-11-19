import BrewCore
import Foundation
import ServiceManagement

@MainActor
@Observable
final class SettingsViewModel {
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let checker: StatusChecker
    @ObservationIgnored private let notifier: BrewNotifier
    @ObservationIgnored private let historyStore: HistoryStore?
    @ObservationIgnored private let defaults: UserDefaults
    /// What macOS actually has registered — the truth `settings.launchAtLogin` is shown from.
    /// Injectable because `SMAppService` only answers meaningfully for an installed .app.
    @ObservationIgnored private let isLaunchAtLoginEnabled: () -> Bool
    @ObservationIgnored var onBrewPathChanged: (@Sendable (String?) -> Void)?
    /// Where the ignored doctor findings go (see `bindIgnoredDoctorWarnings`).
    @ObservationIgnored private weak var ignoredWarningsStore: BrewStore?
    @ObservationIgnored private var savedBrewPath: String?
    @ObservationIgnored private var appliedCheckInterval: AppSettings.CheckInterval?
    @ObservationIgnored private var appliedLaunchAtLogin: Bool?
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
            if oldValue.ignoredDoctorWarnings != settings.ignoredDoctorWarnings {
                ignoredWarningsStore?.setIgnoredDoctorTitles(Set(settings.ignoredDoctorWarnings))
            }
            guard !isLoading, oldValue != settings else { return }
            scheduleSave()
        }
    }

    /// Keeps `store` on the findings these settings ignore — at once on every change, `load()`
    /// included, rather than after the debounced save: an ignored warning leaves the icon at the
    /// click.
    func bindIgnoredDoctorWarnings(to store: BrewStore) {
        ignoredWarningsStore = store
        store.setIgnoredDoctorTitles(Set(settings.ignoredDoctorWarnings))
    }

    /// Hides a doctor finding, by its title, from the icon, the popover and notifications.
    func ignoreDoctorWarning(titled title: String) {
        guard !settings.ignoredDoctorWarnings.contains(title) else { return }
        settings.ignoredDoctorWarnings.append(title)
    }

    func stopIgnoringDoctorWarning(titled title: String) {
        settings.ignoredDoctorWarnings.removeAll { $0 == title }
    }

    var saveError: String?

    init(
        store: SettingsStore,
        checker: StatusChecker,
        notifier: BrewNotifier,
        historyStore: HistoryStore? = nil,
        defaults: UserDefaults = .brewMenu,
        isLaunchAtLoginEnabled: @escaping () -> Bool = { SMAppService.mainApp.status == .enabled }
    ) {
        self.store = store
        self.checker = checker
        self.notifier = notifier
        self.historyStore = historyStore
        self.defaults = defaults
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
    }

    /// Reads the saved settings and applies them to the checker and the notifier. Runs at launch,
    /// not when a window opens: the menu bar icon and the notifications follow these settings from
    /// the first second, and used to run on defaults until the user happened to change something.
    func load() async {
        isLoading = true
        settings = await store.settings
        // The saved flag says what was asked for; SMAppService says what's registered.
        settings.launchAtLogin = isLaunchAtLoginEnabled()
        savedBrewPath = settings.customBrewPath
        appliedCheckInterval = settings.checkInterval
        appliedLaunchAtLogin = settings.launchAtLogin
        isLoading = false
        await checker.setInterval(settings.checkInterval.statusCheckerInterval)
        await configureNotifier()
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
            // Only when the value actually changes: applying it on every save repeated a failure
            // (e.g. running outside /Applications) on unrelated edits.
            if settings.launchAtLogin != appliedLaunchAtLogin {
                appliedLaunchAtLogin = settings.launchAtLogin
                applyLaunchAtLogin(settings.launchAtLogin)
            }
            await configureNotifier()
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
        defaults.removeObject(forKey: "hasCompletedOnboarding")
        settings = AppSettings()
        await save()
    }

    // MARK: - Private

    private func configureNotifier() async {
        await notifier.configure(
            notifyOnUpdates: settings.notifyOnUpdates,
            notifyOnUpgradeFailure: settings.notifyOnUpgradeFailure,
            notifyOnDoctorWarnings: settings.notifyOnDoctorWarnings,
            notifyOnCriticalInsights: settings.notifyOnCriticalInsights
        )
    }

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
