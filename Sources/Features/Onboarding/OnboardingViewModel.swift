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
    // Called with the optional custom brew path when the user taps "Comenzar"
    // or dismisses without completing. Triggers bootstrap in BrewMenuApp.
    @ObservationIgnored let onBootstrap: (String?) -> Void

    init(
        store: SettingsStore,
        notifier: BrewNotifier,
        onBootstrap: @escaping (String?) -> Void
    ) {
        self.needsOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        self.store = store
        self.notifier = notifier
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
        settings.hasCompletedOnboarding = true
        let path = customBrewPath.isEmpty ? nil : customBrewPath
        if let path { settings.customBrewPath = path }
        try? await store.save(settings)
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        isComplete = true
        onBootstrap(path)
    }

    /// Called when the window is dismissed without tapping "Comenzar" (X button).
    /// Runs bootstrap anyway so the app is usable.
    func completeSkipped() async {
        guard !isComplete else { return }
        onBootstrap(customBrewPath.isEmpty ? nil : customBrewPath)
    }
}
