import AppKit
import SwiftUI
import UserNotifications

@main
struct BrewMenuApp: App {
    @NSApplicationDelegateAdaptor(BrewMenuAppDelegate.self) private var appDelegate
    @State private var vm: MenuBarViewModel
    @State private var settingsViewModel: SettingsViewModel
    @State private var dashboardViewModel: DashboardViewModel
    @State private var dashboardNav = DashboardNavigation()
    // StatusChecker is an actor; App structs live for the entire process lifetime,
    // same as the checker itself, so a plain `let` reference is enough.
    private let checker: StatusChecker
    private let onboardingController = OnboardingWindowController()
    // UNUserNotificationCenter's delegate property is weak — this keeps it alive for
    // the process lifetime, same reasoning as `checker`.
    private let notificationDelegate = BrewMenuNotificationDelegate()

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

        let settingsVM = SettingsViewModel(store: store, checker: checker, notifier: notifier)
        settingsVM.onBrewPathChanged = { [vm] newPath in
            Task { @MainActor in vm.start(customBrewPath: newPath) }
        }

        // Guarded the same way BrewNotifier guards `.current()` — calling this without
        // a proper bundle identifier (e.g. `swift build`/`swift run` outside an .app
        // bundle) crashes.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = notificationDelegate
        }

        self.checker = checker
        self._vm = State(initialValue: vm)
        self._settingsViewModel = State(initialValue: settingsVM)
        self._dashboardViewModel = State(initialValue: DashboardViewModel(service: service))

        appDelegate.dashboardNav = dashboardNav

        onboardingController.showIfNeeded(onboardingVM)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        Task { await BrewLogger.shared.log("BrewMenu \(version) started") }

        if !onboardingVM.needsOnboarding {
            runBootstrap(nil)
        }
    }

    /// Keeps the status item inserted unless the user opted into hiding it AND
    /// there's genuinely nothing to attend to right now — `forceShowIcon`/`isWindowOpen`
    /// cover the "reopened while hidden" and "Dashboard is open" cases, both of which
    /// need the icon around as the only way back to Settings/Quit. Not settable: this
    /// app doesn't offer a way to manually remove the item from the menu bar.
    private var iconIsInserted: Binding<Bool> {
        Binding(
            get: {
                !settingsViewModel.settings.hideMenuBarIconWhenClear
                    || vm.hasSomethingToAttendTo
                    || dashboardNav.shouldForceIconVisible
            },
            set: { _ in }
        )
    }

    var body: some Scene {
        MenuBarExtra(isInserted: iconIsInserted) {
            MenuBarView(viewModel: vm, dashboardNav: dashboardNav)
                .onAppear { Task { await checker.startServicesPolling() } }
                .onDisappear { Task { await checker.stopServicesPolling() } }
        } label: {
            MenuBarIconLabel(status: vm.status, showBadge: settingsViewModel.settings.showUpdateBadge, dashboardNav: dashboardNav)
        }
        .menuBarExtraStyle(.window)

        Window("BrewMenu Dashboard", id: "dashboard") {
            DashboardView(
                viewModel: vm,
                settingsViewModel: settingsViewModel,
                dashboardViewModel: dashboardViewModel,
                navigation: dashboardNav
            )
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            // Accessory-policy (menu-bar-only) apps don't get a standard Edit menu
            // for free — without this, Cmd+C/X/V/A silently do nothing in any
            // text field across the app, since no menu item's key equivalent is
            // wired to the first responder's standard editing actions.
            CommandGroup(replacing: .pasteboard) {
                Button(L("Cut")) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x", modifiers: .command)
                Button(L("Copy")) { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                Button(L("Paste")) { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v", modifiers: .command)
                Divider()
                Button(L("Select All")) { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a", modifiers: .command)
            }
        }
    }
}
