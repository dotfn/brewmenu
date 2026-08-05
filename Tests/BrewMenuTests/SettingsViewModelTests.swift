import Testing
import Foundation
@testable import BrewMenu

@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {

    // MARK: - Helpers

    private func makeSettingsStore() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SettingsStore(directory: dir)
    }

    private func makeStatusChecker() -> StatusChecker {
        StatusChecker(service: MockBrewService(), onPackagesUpdated: { _ in }, onError: { _ in })
    }

    private func makeViewModel(store: SettingsStore? = nil) -> SettingsViewModel {
        SettingsViewModel(
            store: store ?? makeSettingsStore(),
            checker: makeStatusChecker(),
            notifier: BrewNotifier(),
            historyStore: nil
        )
    }

    // MARK: - resetAllData() / hasCompletedOnboarding

    @Test("resetAllData() limpia el flag de onboarding en UserDefaults — 'Reset all data' vuelve a mostrar el onboarding")
    func resetAllDataClearsOnboardingFlag() async {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        defer { UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding") }

        let vm = makeViewModel()
        await vm.resetAllData()

        #expect(UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") == false)
    }

    @Test("resetAllData() deja settings en sus valores por defecto")
    func resetAllDataResetsSettings() async {
        defer { UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding") }

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

    // MARK: - Autosave

    @Test("cambiar settings dispara un autosave por sí solo, sin que nadie llame a save() explícitamente")
    func settingsChangeTriggersAutosave() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vm = makeViewModel(store: SettingsStore(directory: dir))
        await vm.load()

        vm.settings.showUpdateBadge = false

        // Más que el debounce de 400ms de `scheduleSave()`.
        try? await Task.sleep(nanoseconds: 700_000_000)

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

        try? await Task.sleep(nanoseconds: 700_000_000)

        let reloaded = SettingsStore(directory: dir)
        let settings = await reloaded.settings
        #expect(settings.showUpdateBadge == false)
        #expect(settings.checkInterval == .daily)
        #expect(settings.hideMenuBarIconWhenClear == true)
    }
}
