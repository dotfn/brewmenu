import Foundation

@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: CaseIterable { case welcome, notifications, brewDetection }

    let needsOnboarding: Bool

    private(set) var step: Step = .welcome
    private(set) var detectedBrewPath: String? = nil
    private(set) var isDetecting: Bool = false
    private(set) var notificationsGranted: Bool? = nil  // nil = not requested yet
    private(set) var isComplete: Bool = false

    var customBrewPath: String = ""

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let notifier: BrewNotifier
    // `hasCompletedOnboarding`'s single source of truth — UserDefaults, not AppSettings/
    // SettingsStore, because this needs to be readable synchronously at init time,
    // before BrewMenuApp has had a chance to run any async work. Injectable so tests
    // can point it at an isolated suite instead of the real UserDefaults.standard.
    @ObservationIgnored private let defaultsStore: UserDefaults
    // Called with the optional custom brew path when the user taps "Comenzar"
    // or dismisses without completing. Triggers bootstrap in BrewMenuApp.
    @ObservationIgnored let onBootstrap: (String?) -> Void

    init(
        store: SettingsStore,
        notifier: BrewNotifier,
        defaultsStore: UserDefaults = .standard,
        onBootstrap: @escaping (String?) -> Void
    ) {
        self.needsOnboarding = !defaultsStore.bool(forKey: "hasCompletedOnboarding")
        self.store = store
        self.notifier = notifier
        self.defaultsStore = defaultsStore
        self.onBootstrap = onBootstrap
    }

    // MARK: - Navigation

    func advance() {
        switch step {
        case .welcome: step = .notifications
        case .notifications: step = .brewDetection
        case .brewDetection: break
        }
    }

    // MARK: - Step actions

    func detectBrew() async {
        isDetecting = true
        defer { isDetecting = false }
        let resolver = EnvironmentResolver()
        detectedBrewPath = try? await resolver.detectBrewPath()
    }

    func requestNotifications() async {
        notificationsGranted = await notifier.requestAuthorization()
    }

    /// Saves the onboarding flag, then triggers bootstrap.
    func complete() async {
        guard !isComplete else { return }
        var settings = await store.settings
        let path = customBrewPath.isEmpty ? nil : customBrewPath
        if let path { settings.customBrewPath = path }
        try? await store.save(settings)
        defaultsStore.set(true, forKey: "hasCompletedOnboarding")
        isComplete = true
        onBootstrap(path)
    }

    /// Called when the window is dismissed without tapping "Comenzar" (X button).
    /// Runs bootstrap anyway so the app is usable.
    func completeSkipped() async {
        guard !isComplete else { return }
        isComplete = true
        onBootstrap(customBrewPath.isEmpty ? nil : customBrewPath)
    }
}
