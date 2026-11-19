import AppKit
import BrewCore
import SwiftUI
import UserNotifications

@main
struct BrewMenuApp: App {
    @NSApplicationDelegateAdaptor(BrewMenuAppDelegate.self) private var appDelegate
    @State private var vm: MenuBarViewModel
    @State private var settingsViewModel: SettingsViewModel
    @State private var dashboardViewModel: DashboardViewModel
    /// Read in `init` (to hand it to the app delegate), which @State forbids before SwiftUI
    /// installs it. It's an @Observable class, so views still update through a plain reference.
    private let dashboardNav = DashboardNavigation()
    // StatusChecker is an actor; App structs live for the entire process lifetime,
    // same as the checker itself, so a plain `let` reference is enough.
    private let checker: StatusChecker
    private let onboardingController = OnboardingWindowController()
    /// UNUserNotificationCenter's delegate property is weak — this keeps it alive for
    /// the process lifetime, same reasoning as `checker`.
    private let notificationDelegate = BrewMenuNotificationDelegate()

    init() {
        // Must be set before any scene or window is created so SwiftUI never
        // shows a Dock icon or auto-opens a main window.
        NSApplication.shared.setActivationPolicy(.accessory)

        let resolver = EnvironmentResolver()
        let operations = BrewOperations()
        let service = BrewService(resolver: resolver, operations: operations, localIndex: .homebrewDefault)
        let notifier = BrewNotifier()
        let store = SettingsStore()
        let historyStore = HistoryStore()
        // The one copy of brew's state: the menu bar, the Dashboard and the checker all share it.
        let brewStore = BrewStore(
            service: service,
            historyStore: historyStore,
            notifier: notifier,
            installedCache: InstalledPackagesCache(),
            packageCatalog: PackageCatalog()
        )
        let vm = MenuBarViewModel(
            service: service,
            notifier: notifier,
            operations: operations,
            store: brewStore
        )

        let checker = StatusChecker(store: brewStore, interval: .hourly)

        let settingsVM = SettingsViewModel(
            store: store,
            checker: checker,
            notifier: notifier,
            historyStore: historyStore
        )
        settingsVM.onBrewPathChanged = { [vm] newPath in
            Task { @MainActor in vm.start(customBrewPath: newPath) }
        }
        // Before `load()` below, which delivers the saved list.
        settingsVM.bindIgnoredDoctorWarnings(to: brewStore)
        // Right away, not when a window opens: the menu bar icon and the notifier follow these.
        Task { await settingsVM.load() }

        let runBootstrap: (String?) -> Void = { [vm, checker, notifier, historyStore, settingsVM] customPath in
            Task {
                // An isolated run (BREWMENU_DATA_DIR, used by the UI tests) must not raise the system's
                // notification prompt, which nobody answers in a test host.
                if BrewMenuDataRoots.environmentOverride == nil {
                    // Its own task: this returns only once the user answers the system prompt, and
                    // an unanswered prompt held back the first check (the icon stayed on
                    // "initializing") and the scheduled ones.
                    Task { await notifier.requestAuthorization() }
                }
                try? await historyStore.prune(olderThan: 30)
                // Again here: onboarding may have just saved a Homebrew path. Applies the interval too.
                await settingsVM.load()
                let savedPath = EnvironmentResolver.usableCustomPath(settingsVM.settings.customBrewPath) {
                    FileManager.default.isExecutableFile(atPath: $0)
                }
                await vm.performBootstrap(customBrewPath: customPath ?? savedPath)
                await checker.start()
                // The checker's own doctor run comes an hour in, then daily (never, with "Manual").
                await vm.store.runDoctor()
            }
        }

        let onboardingVM = OnboardingViewModel(
            store: store,
            notifier: notifier,
            onBootstrap: runBootstrap
        )

        // Guarded the same way BrewNotifier guards `.current()` — calling this without
        // a proper bundle identifier (e.g. `swift build`/`swift run` outside an .app
        // bundle) crashes.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = notificationDelegate
        }

        let dashboardVM = DashboardViewModel(service: service, store: brewStore)

        self.checker = checker
        _vm = State(initialValue: vm)
        _settingsViewModel = State(initialValue: settingsVM)
        _dashboardViewModel = State(initialValue: dashboardVM)

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
            MenuBarIconLabel(
                status: vm.status,
                showBadge: settingsViewModel.settings.showUpdateBadge,
                dashboardNav: dashboardNav,
                lastChecked: vm.lastChecked
            )
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
            // View ▸ Show/Hide Sidebar (⌃⌘S), which a sidebar window is expected to have.
            SidebarCommands()
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
