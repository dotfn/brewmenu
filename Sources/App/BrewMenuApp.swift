import AppKit
import SwiftUI

@main
struct BrewMenuApp: App {
    @State private var settingsViewModel: SettingsViewModel
    // StatusItemController owns the NSStatusItem, NSPopover, and MenuBarViewModel.
    // Stored as a plain let — App structs live for the entire process lifetime.
    private let controller: StatusItemController

    init() {
        // Must be set before any scene or window is created so SwiftUI never
        // shows a Dock icon or auto-opens a main window.
        NSApplication.shared.setActivationPolicy(.accessory)

        let resolver = EnvironmentResolver()
        let service = BrewService(resolver: resolver)
        let notifier = BrewNotifier()
        let store = SettingsStore()
        let historyStore = HistoryStore()
        let vm = MenuBarViewModel(service: service, notifier: notifier, historyStore: historyStore)

        let checker = StatusChecker(
            service: service,
            historyStore: historyStore,
            interval: .hourly,
            onPackagesUpdated: { [vm, notifier] packages in
                Task { @MainActor in vm.updatePackages(packages) }
                Task { await notifier.notifyIfUpdatesIncreased(to: packages.count) }
            },
            onDoctorCompleted: { [vm] warnings in
                Task { @MainActor in vm.updateDoctorWarnings(warnings) }
            },
            onServicesUpdated: { [vm] entries in
                Task { @MainActor in vm.updateServices(entries) }
            },
            onError: { [vm] error in
                Task { @MainActor in vm.handleBackgroundError(error) }
            }
        )

        let runBootstrap: (String?) -> Void = { [vm, checker, notifier, historyStore, store] customPath in
            Task {
                await notifier.requestAuthorization()
                try? await historyStore.prune(olderThan: 30)
                let savedSettings = await store.settings
                await checker.setInterval(savedSettings.checkInterval.statusCheckerInterval)
                await vm.performBootstrap(customBrewPath: customPath ?? savedSettings.customBrewPath)
                await checker.start()
            }
        }

        let onboardingVM = OnboardingViewModel(
            store: store,
            notifier: notifier,
            onBootstrap: runBootstrap
        )

        self._settingsViewModel = State(initialValue: SettingsViewModel(
            store: store,
            checker: checker,
            notifier: notifier
        ))
        self.controller = StatusItemController(viewModel: vm, onboardingViewModel: onboardingVM)

        if !onboardingVM.needsOnboarding {
            runBootstrap(nil)
        }
    }

    var body: some Scene {
        Settings {
            SettingsView(viewModel: settingsViewModel)
        }
    }
}
