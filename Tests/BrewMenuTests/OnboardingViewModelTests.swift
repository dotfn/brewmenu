@testable import BrewMenu
import Foundation
import Testing

@Suite("OnboardingViewModel")
@MainActor
struct OnboardingViewModelTests {
    // MARK: - Helpers

    /// An isolated `UserDefaults` suite per test, so `hasCompletedOnboarding` never
    /// leaks between tests or touches the real `UserDefaults.standard`.
    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "OnboardingViewModelTests.\(UUID().uuidString)")!
    }

    private func makeSettingsStore() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SettingsStore(directory: dir)
    }

    private func makeViewModel(
        defaults: UserDefaults,
        onBootstrap: @escaping (String?) -> Void = { _ in }
    ) -> OnboardingViewModel {
        OnboardingViewModel(
            store: makeSettingsStore(),
            notifier: BrewNotifier(),
            defaultsStore: defaults,
            onBootstrap: onBootstrap
        )
    }

    // MARK: - needsOnboarding / single source of truth

    @Test("needsOnboarding es true cuando el flag no está seteado")
    func needsOnboardingIsTrueWhenFlagNotSet() {
        let vm = makeViewModel(defaults: makeIsolatedDefaults())
        #expect(vm.needsOnboarding)
    }

    @Test("needsOnboarding es false después de complete() — UserDefaults es la única fuente de verdad")
    func needsOnboardingIsFalseAfterComplete() async {
        let defaults = makeIsolatedDefaults()
        let first = makeViewModel(defaults: defaults)
        await first.complete()

        // Un segundo view model, mismo suite de UserDefaults — simula un relanzamiento.
        let second = makeViewModel(defaults: defaults)
        #expect(!second.needsOnboarding)
    }

    @Test("completeSkipped() no marca el onboarding como completo — vuelve a aparecer en el próximo lanzamiento")
    func completeSkippedDoesNotPersistFlag() async {
        let defaults = makeIsolatedDefaults()
        let first = makeViewModel(defaults: defaults)
        await first.completeSkipped()

        let second = makeViewModel(defaults: defaults)
        #expect(second.needsOnboarding)
    }

    // MARK: - complete()

    // Regression: "Get started" accepted any typed path, and the bootstrap then failed
    // later with a confusing "not found" error. An unrunnable path must stop here.
    @Test("complete() con una ruta que no es ejecutable no avanza ni dispara bootstrap")
    func completeRejectsUnrunnableCustomPath() async {
        nonisolated(unsafe) var bootstrapCalls = 0
        let vm = makeViewModel(defaults: makeIsolatedDefaults(), onBootstrap: { _ in bootstrapCalls += 1 })
        vm.isExecutablePath = { _ in false }
        vm.customBrewPath = "/opt/homebrew/bin/bre"

        await vm.complete()

        #expect(!vm.customPathIsValid)
        #expect(!vm.isComplete)
        #expect(bootstrapCalls == 0)
    }

    @Test("complete() dispara onBootstrap con el customBrewPath ingresado")
    func completeTriggersBootstrapWithPath() async {
        nonisolated(unsafe) var receivedPath: String??
        let vm = makeViewModel(defaults: makeIsolatedDefaults(), onBootstrap: { receivedPath = $0 })
        vm.customBrewPath = "/opt/homebrew/bin/brew"
        vm.isExecutablePath = { _ in true }

        await vm.complete()

        #expect(receivedPath == .some("/opt/homebrew/bin/brew"))
    }

    @Test("complete() es idempotente — llamarlo dos veces no dispara onBootstrap dos veces")
    func completeIsIdempotent() async {
        nonisolated(unsafe) var callCount = 0
        let vm = makeViewModel(defaults: makeIsolatedDefaults(), onBootstrap: { _ in callCount += 1 })

        await vm.complete()
        await vm.complete()

        #expect(callCount == 1)
    }
}
