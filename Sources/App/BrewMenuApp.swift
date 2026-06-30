import AppKit
import SwiftUI

@main
struct BrewMenuApp: App {
    @State private var viewModel: MenuBarViewModel
    @State private var settingsViewModel: SettingsViewModel
    @State private var onboardingViewModel: OnboardingViewModel
    private let checker: StatusChecker
    private let notifier: BrewNotifier

    init() {
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
            // Dispatch back to MainActor — los callbacks vienen del actor StatusChecker
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

        // Bootstrap closure shared by normal launch and onboarding completion.
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

        self._viewModel = State(initialValue: vm)
        self._settingsViewModel = State(initialValue: SettingsViewModel(store: store, checker: checker, notifier: notifier))
        self._onboardingViewModel = State(initialValue: onboardingVM)
        self.checker = checker
        self.notifier = notifier

        // Skip bootstrap at init when onboarding is pending — OnboardingViewModel.complete()
        // triggers it via onBootstrap once the user finishes the wizard.
        if !onboardingVM.needsOnboarding {
            runBootstrap(nil)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            // OnboardingLauncher opens the onboarding window at launch when needed.
            // It lives here because the label view is always rendered, unlike the popover
            // content which only appears when the user clicks the icon.
            OnboardingLauncher(
                symbolName: viewModel.status.menuBarSymbol,
                color: viewModel.status.menuBarColor,
                needsOnboarding: onboardingViewModel.needsOnboarding
            )
        }
        .menuBarExtraStyle(.window)

        // Shown automatically at first launch via OnboardingLauncher.task.
        // SwiftUI has no mechanism to auto-open a Window scene at launch on macOS 14,
        // so openWindow is called from the always-visible menu bar label view.
        Window("Bienvenido a BrewMenu", id: "onboarding") {
            OnboardingView(viewModel: onboardingViewModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView(viewModel: settingsViewModel)
        }
    }
}

// MARK: - OnboardingLauncher

private struct OnboardingLauncher: View {
    let symbolName: String
    let color: Color
    let needsOnboarding: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        menuBarImage(systemName: symbolName, color: color)
            .task {
                guard needsOnboarding else { return }
                openWindow(id: "onboarding")
            }
    }
}

// NSStatusItem forces template-image rendering on SwiftUI views, stripping color.
// A non-template NSImage is the only reliable way to show a colored menu bar icon.
private func menuBarImage(systemName: String, color: Color) -> Image {
    let cfg = NSImage.SymbolConfiguration(paletteColors: [NSColor(color)])
    guard let img = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else {
        return Image(systemName: systemName)
    }
    img.isTemplate = false
    img.size = NSSize(width: 18, height: 18)
    return Image(nsImage: img)
}

// MARK: - MenuBarExtra icon per status

private extension MenuBarStatus {
    var menuBarSymbol: String {
        switch self {
        case .initializing: "hourglass"
        case .ok: "mug.fill"
        case .updates: "mug.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var menuBarColor: Color {
        switch self {
        case .initializing: .secondary
        case .ok: .green
        case .updates: .yellow
        case .warning: .orange
        case .error: .red
        }
    }
}
