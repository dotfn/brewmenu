import BrewCore
@testable import BrewMenu
import Foundation
import Testing

@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {
    // MARK: - Helpers

    private func makeSettingsStore() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SettingsStore(directory: dir)
    }

    private func makeStatusChecker() -> StatusChecker {
        StatusChecker(store: BrewStore(service: MockBrewService()))
    }

    private let defaults = UserDefaults(suiteName: "SettingsViewModelTests.\(UUID().uuidString)")!

    private func makeViewModel(
        store: SettingsStore? = nil,
        notifier: BrewNotifier = BrewNotifier(),
        launchAtLoginEnabled: Bool = false
    ) -> SettingsViewModel {
        SettingsViewModel(
            store: store ?? makeSettingsStore(),
            checker: makeStatusChecker(),
            notifier: notifier,
            historyStore: nil,
            defaults: defaults,
            isLaunchAtLoginEnabled: { launchAtLoginEnabled }
        )
    }

    // MARK: - resetAllData() / hasCompletedOnboarding

    @Test(
        "resetAllData() limpia el flag de onboarding en UserDefaults — 'Reset all data' vuelve a mostrar el onboarding"
    )
    func resetAllDataClearsOnboardingFlag() async {
        defaults.set(true, forKey: "hasCompletedOnboarding")

        let vm = makeViewModel()
        await vm.resetAllData()

        #expect(defaults.bool(forKey: "hasCompletedOnboarding") == false)
    }

    @Test("resetAllData() deja settings en sus valores por defecto")
    func resetAllDataResetsSettings() async {
        let vm = makeViewModel()
        await vm.load()
        vm.settings.showUpdateBadge = false
        vm.settings.checkInterval = .daily

        await vm.resetAllData()

        #expect(vm.settings == AppSettings())
    }

    // MARK: - load()

    @Test("load() puebla settings desde el store")
    func loadPopulatesSettingsFromStore() async {
        let store = makeSettingsStore()
        var saved = AppSettings()
        saved.showUpdateBadge = false
        try? await store.save(saved)

        let vm = makeViewModel(store: store)
        await vm.load()

        #expect(vm.settings.showUpdateBadge == false)
    }

    // Regression: the notifier only got the user's preferences from save(), so after every relaunch it
    // ran on defaults (everything on) until some unrelated setting was changed.
    @Test("load() aplica las preferencias de notificación guardadas al notifier")
    func loadConfiguresNotifier() async {
        let store = makeSettingsStore()
        var saved = AppSettings()
        saved.notifyOnUpdates = false
        saved.notifyOnDoctorWarnings = false
        try? await store.save(saved)
        let notifier = BrewNotifier()

        let vm = makeViewModel(store: store, notifier: notifier)
        await vm.load()

        let preferences = await notifier.preferences
        #expect(preferences.updates == false)
        #expect(preferences.doctorWarnings == false)
        #expect(preferences.upgradeFailure == true)
    }

    @Test("load() muestra Launch at Login según lo registrado en macOS, no según el archivo")
    func loadReflectsRegisteredLaunchAtLogin() async {
        let store = makeSettingsStore()
        var saved = AppSettings()
        saved.launchAtLogin = true
        try? await store.save(saved)

        let vm = makeViewModel(store: store, launchAtLoginEnabled: false)
        await vm.load()

        #expect(vm.settings.launchAtLogin == false)
    }

    // MARK: - Autosave

    @Test("cambiar settings dispara un autosave por sí solo, sin que nadie llame a save() explícitamente")
    func settingsChangeTriggersAutosave() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vm = makeViewModel(store: SettingsStore(directory: dir))
        await vm.load()

        vm.settings.showUpdateBadge = false

        // Espera a que el debounce de `scheduleSave()` (400ms) escriba a disco.
        try? await waitUntil { await SettingsStore(directory: dir).settings.showUpdateBadge == false }

        // Un SettingsStore nuevo apuntando al mismo directorio — lee lo que haya en
        // disco, sin que este test haya llamado a save() en ningún momento.
        let reloaded = SettingsStore(directory: dir)
        #expect(await reloaded.settings.showUpdateBadge == false)
    }

    @Test("load() no dispara un autosave — no reescribe el archivo que acaba de leer")
    func loadDoesNotTriggerAutosave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SettingsStore(directory: dir)
        var saved = AppSettings()
        saved.showUpdateBadge = false
        try await store.save(saved)

        let fileURL = dir.appendingPathComponent("settings.json")
        let mtimeBeforeLoad = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        let vm = makeViewModel(store: store)
        await vm.load()

        try? await Task.sleep(nanoseconds: 700_000_000)

        let mtimeAfterLoad = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        #expect(mtimeBeforeLoad == mtimeAfterLoad)
    }

    @Test("varios cambios seguidos se coalescen en un solo save, no uno por cambio")
    func rapidChangesCoalesceIntoOneSave() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vm = makeViewModel(store: SettingsStore(directory: dir))
        await vm.load()

        // Tres cambios seguidos, cada uno bien dentro de la ventana de debounce del anterior.
        vm.settings.showUpdateBadge = false
        try? await Task.sleep(nanoseconds: 100_000_000)
        vm.settings.checkInterval = .daily
        try? await Task.sleep(nanoseconds: 100_000_000)
        vm.settings.hideMenuBarIconWhenClear = true

        try? await waitUntil { await SettingsStore(directory: dir).settings.hideMenuBarIconWhenClear == true }

        let reloaded = SettingsStore(directory: dir)
        let settings = await reloaded.settings
        #expect(settings.showUpdateBadge == false)
        #expect(settings.checkInterval == .daily)
        #expect(settings.hideMenuBarIconWhenClear == true)
    }
}

// Regression: a settings file that couldn't be decoded was replaced by defaults on the
// next save — everything the user had configured was overwritten without a trace.
@Suite("SettingsStore — archivo ilegible")
struct SettingsStoreUnreadableFileTests {
    @Test("un settings.json que no se puede leer se respalda, no se sobrescribe")
    func unreadableSettingsAreKeptAside() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = dir.appendingPathComponent("settings.json")
        try Data("{ not valid json".utf8).write(to: original)

        let store = SettingsStore(directory: dir)
        try await store.save(AppSettings())

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backups = files.filter { $0.hasPrefix("settings.unreadable-") }
        #expect(backups.count == 1)
        let kept = try String(contentsOf: dir.appendingPathComponent(backups[0]), encoding: .utf8)
        #expect(kept == "{ not valid json")
    }
}
