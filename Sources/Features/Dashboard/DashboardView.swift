import AppKit
import BrewCore
import SwiftUI

struct DashboardView: View {
    let viewModel: MenuBarViewModel
    let settingsViewModel: SettingsViewModel
    @Bindable var dashboardViewModel: DashboardViewModel
    @Bindable var navigation: DashboardNavigation

    /// A plain @State backing .searchable, rather than a computed Binding straight to the
    /// view model — a get/set Binding here was silently breaking onSubmit(of: .search) on
    /// macOS (typing and picking a suggestion worked, but pressing Return did nothing).
    @State private var searchText: String = ""

    // Also a plain @State, not `$navigation.selectedSection` directly, and for the same
    // reason: no row is ever tagged `.searchResults` (removed — a permanently-shown
    // sidebar row for it looked wrong), so binding the List straight to
    // `navigation.selectedSection` meant macOS's List(selection:) had no tag to resolve
    // that value against and silently wrote the *previous* real section back over it —
    // navigating to Search Results (e.g. pressing Return in the search field while
    // viewing another section) would appear to just do nothing. Syncing through a
    // separate @State sidesteps that: the List never sees a value it can't tag-match.
    @State private var sidebarSelection: DashboardSection = .home
    // `.onSubmit(of: .search)` is unreliable here — pressing Return after navigating
    // away from Search Results and clicking back into the field often does nothing
    // (a known rough edge of `.searchable` + `NavigationSplitView` on macOS; the
    // `searchText`-as-plain-@State workaround above already documents one variant of
    // it). Watching focus instead sidesteps Return entirely for the one case that
    // actually needs fixing: jumping back to already-computed results.
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarSelection) {
                Section {
                    ForEach(DashboardSection.mainSections, id: \.self) { section in
                        if section == .outdatedPackages {
                            updatesRow
                        } else {
                            Label(section.title, systemImage: section.systemImage).tag(section)
                        }
                    }
                }
                Section(L("Taps")) {
                    // A direct, discoverable way to the same overview Home's "Active
                    // ecosystems" stat opens — without this, that count (official +
                    // third-party combined) had no sidebar-reachable destination at all.
                    Label(L("Overview"), systemImage: DashboardSection.ecosystemsOverview.systemImage)
                        .tag(DashboardSection.ecosystemsOverview)
                    ForEach(dashboardViewModel.officialEcosystems) { tap in
                        Label(tap.displayName, systemImage: DashboardSection.ecosystem(tap.name).systemImage)
                            .tag(DashboardSection.ecosystem(tap.name))
                    }
                    // Always shown, even with zero third-party taps: this is the only
                    // entry point to the "Add" sheet (add a tap, or install a formula/cask
                    // by exact name) — gating it on `!thirdPartyTaps.isEmpty` made it
                    // unreachable for the common case of a user with only Homebrew-core/
                    // cask packages installed. ThirdPartyEcosystemsView's own empty state
                    // already surfaces the "Add…" action when there's nothing here yet.
                    Label(L("Third-Party"), systemImage: DashboardSection.thirdPartyEcosystems.systemImage)
                        .tag(DashboardSection.thirdPartyEcosystems)
                }
                Section(L("Tools")) {
                    ForEach(DashboardSection.toolSections, id: \.self) { section in
                        Label(section.title, systemImage: section.systemImage).tag(section)
                    }
                }
                // One entry for every setting (see `SettingsPage`), on its own at the bottom like a
                // footer: a "Settings" heading over a single "Settings" row would only repeat it.
                Section {
                    Label(DashboardSection.settings.title, systemImage: DashboardSection.settings.systemImage)
                        .tag(DashboardSection.settings)
                }
            }
            .navigationSplitViewColumnWidth(230)
        } detail: {
            // A plain VStack, not `.safeAreaInset(edge: .top)` — on this detail pane
            // (NavigationSplitView + a ScrollView/List-based child) safeAreaInset rendered
            // as a floating overlay on top of the first row of content instead of pushing
            // it down. The MenuBar popover already shows this banner, but a user who
            // upgrades BrewMenu itself from the Dashboard's Outdated Packages list (rather
            // than the popover) might never open the popover again and would otherwise
            // never learn a restart is needed.
            VStack(spacing: 0) {
                if viewModel.needsRestart {
                    RestartBanner(horizontalPadding: 16, verticalPadding: 10)
                }
                // Pages open on top of the section (a collection, a package) instead of in sheets,
                // so the list stays where it was and Back returns to it — the App Store's way.
                NavigationStack(path: $navigation.path) {
                    detailContent
                        .navigationTitle(navigation.selectedSection.title)
                        .navigationDestination(for: DashboardRoute.self) { route in
                            switch route {
                            case let .collection(pack):
                                CollectionDetailView(pack: pack, dashboardViewModel: dashboardViewModel)
                            case let .package(target):
                                PackageDetailView(target: target, dashboardViewModel: dashboardViewModel)
                            }
                        }
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: L("Search Homebrew…"))
        .searchFocused($isSearchFieldFocused)
        .onChange(of: isSearchFieldFocused) { _, focused in
            guard focused else { return }
            let trimmed = searchText.trimmingCharacters(in: .whitespaces)
            // Just navigates back — `searchResults` is already sitting there from the
            // last real search, so there's nothing to re-run.
            guard !trimmed.isEmpty, navigation.selectedSection != .searchResults else { return }
            navigation.selectedSection = .searchResults
        }
        .onSubmit(of: .search) {
            runSearch(searchText)
        }
        .onChange(of: searchText) { _, newValue in
            dashboardViewModel.updateSearch(for: newValue)
            // New results replace whatever package page was opened from the old ones.
            if navigation.selectedSection == .searchResults { navigation.path = [] }
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                navigation.selectedSection = .searchResults
            } else if navigation.selectedSection == .searchResults {
                navigation.selectedSection = .home
            }
        }
        // Clicking a real sidebar row updates the source of truth directly.
        .onChange(of: sidebarSelection) { _, newValue in
            navigation.selectedSection = newValue
        }
        // ...and the reverse, for every OTHER way `selectedSection` changes (search
        // navigation, the menu bar icon's "open dashboard to X" notification, etc.) —
        // except `.searchResults` itself, which `sidebarSelection` deliberately never
        // becomes (see its declaration above).
        .onChange(of: navigation.selectedSection) { _, newValue in
            if newValue != .searchResults { sidebarSelection = newValue }
        }
        .frame(minWidth: 700, minHeight: 450)
        .task { await dashboardViewModel.load() }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            // The app is menu-bar-only (`.accessory`) so the Dock stays clean; while the
            // Dashboard is open it gets a Dock icon like any regular window.
            NSApplication.shared.setActivationPolicy(.regular)
            navigation.isWindowOpen = true
            // Seeds `sidebarSelection` for the case where `navigation.selectedSection`
            // was already set to something other than `.home` before this view ever
            // appeared — e.g. a menu bar notification's "open dashboard to X" — which
            // the `onChange` above can't catch since nothing changed after that point.
            if navigation.selectedSection != .searchResults {
                sidebarSelection = navigation.selectedSection
            }
        }
        // Keeps the menu bar icon visible for as long as this window is open — the
        // only way back to Settings/Quit while it's up — then lets it hide again
        // (once StatusChecker's next `hasSomethingToAttendTo` evaluation says so).
        .onDisappear {
            NSApplication.shared.setActivationPolicy(.accessory)
            navigation.isWindowOpen = false
            navigation.forceShowIcon = false
            // Kept app-wide: left set, the sheet would come back on its own when the window does.
            navigation.showsUpgradeLog = false
        }
        .sheet(isPresented: Binding(
            get: { dashboardViewModel.isInstalling },
            // A real setter — without one, Esc/click-outside couldn't dismiss this sheet
            // at all. Routes through `dismissInstallSheet()` so an install still in
            // flight gets stopped rather than left running with no UI attached to it.
            set: { isPresented in if !isPresented { dashboardViewModel.dismissInstallSheet() } }
        )) {
            InstallLogView(dashboardViewModel: dashboardViewModel)
                .interactiveDismissDisabled(dashboardViewModel.isInstallRunning || dashboardViewModel
                    .isCancellingInstall)
        }
        // Same pattern as the package installer: stays open after the run so the result and log can
        // be read, closed by an explicit Done. Can't be dismissed mid-run. At the root, like the
        // install sheet, so every upgrade started in this window shows it (see `showsUpgradeLog`).
        // Closed however it's closed — Done or Esc — the failure it showed has been seen, so the
        // menu bar icon drops it too.
        .sheet(isPresented: $navigation.showsUpgradeLog, onDismiss: { viewModel.clearUpgradeFailure() }) {
            UpgradeLogSheet(viewModel: viewModel, onRetry: { viewModel.upgradeAll() }) {
                navigation.showsUpgradeLog = false
            }
            // Open while brew runs; closable again once it's being cancelled (the cancel goes on).
            .interactiveDismissDisabled(viewModel.isRunningAnyUpgrade && !viewModel.isCancellingUpgrade)
        }
        // Fires once per failed uninstall, from wherever it was triggered (Installed,
        // any Ecosystem/Category, Trending, Search Results) — a tooltip on a small trash
        // icon is easy to never notice; this can't be missed. `uninstallErrors[name]`
        // itself stays set afterward so the row's tooltip still explains it on revisit.
        .alert(
            L("Can't remove \(dashboardViewModel.uninstallFailureAlertName ?? "")"),
            isPresented: Binding(
                get: { dashboardViewModel.uninstallFailureAlertName != nil },
                set: { if !$0 { dashboardViewModel.uninstallFailureAlertName = nil } }
            )
        ) {
            // The message can be a command to run in Terminal; an alert's text can't be selected.
            Button(L("Copy error")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    dashboardViewModel.uninstallErrors[dashboardViewModel.uninstallFailureAlertName ?? ""] ?? "",
                    forType: .string
                )
                dashboardViewModel.uninstallFailureAlertName = nil
            }
            Button(L("OK"), role: .cancel) { dashboardViewModel.uninstallFailureAlertName = nil }
        } message: {
            Text(dashboardViewModel.uninstallErrors[dashboardViewModel.uninstallFailureAlertName ?? ""] ?? "")
        }
        // Failures with no row or sheet of their own (see `ActionFailure`).
        .alert(
            dashboardViewModel.actionFailure?.title ?? "",
            isPresented: Binding(
                get: { dashboardViewModel.actionFailure != nil },
                set: {
                    if !$0 {
                        dashboardViewModel.actionFailure = nil
                    }
                }
            ),
            presenting: dashboardViewModel.actionFailure
        ) { failure in
            Button(L("Copy error")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(failure.details, forType: .string)
            }
            Button(L("OK"), role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        // Lets the reusable browse-row family (PackageBrowseRow/PackageStatusIndicator/
        // PackageInfoButton/InstalledStatusButton in StatusBadge.swift) read
        // DashboardViewModel from the environment instead of having it re-threaded through
        // every intermediate view purely to reach those leaves. Last in the chain, after the
        // sheets: a sheet gets the environment of the place its `.sheet` is applied, so with these
        // applied first the sheets went without them — and the upgrade sheet's package icon,
        // which reads DashboardViewModel, crashed the app the moment an upgrade started.
        .environment(dashboardViewModel)
        // The catalog rows' Update pill upgrades through the menu bar's view model, which owns
        // upgrades; their sheet is the one above, raised through `DashboardNavigation.showsUpgradeLog`.
        .environment(viewModel)
        // Rows open package pages through it (see `DashboardNavigation.openPackage`).
        .environment(navigation)
    }

    /// Updates, with how many there are on the right — a composed row instead of `.badge()`, which
    /// on a sidebar row inside `List(selection:)` can swallow the row's click.
    private var updatesRow: some View {
        let count = viewModel.outdatedPackages.count
        let section = DashboardSection.outdatedPackages
        return HStack {
            // The count is read as the label's value: combining the row into one element would
            // rename it ("Updates, 2 available") and lose the plain "Updates" a UI test finds.
            Label(section.title, systemImage: section.systemImage)
                .accessibilityValue(count > 0 ? L("\(count) available") : "")
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .tag(section)
    }

    private func runSearch(_ query: String) {
        searchText = query
        navigation.selectedSection = .searchResults
        Task { await dashboardViewModel.commitSearch(query) }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch navigation.selectedSection {
        case .home: HomeView(dashboardViewModel: dashboardViewModel, navigation: navigation)
        case .apps: CatalogBrowseView(kind: .apps, dashboardViewModel: dashboardViewModel)
        case .commandLine: CatalogBrowseView(kind: .commandLine, dashboardViewModel: dashboardViewModel)
        case .installed: InstalledView(dashboardViewModel: dashboardViewModel)
        case .outdatedPackages: OutdatedPackagesSection(viewModel: viewModel, dashboardViewModel: dashboardViewModel)
        case .ecosystemsOverview: EcosystemsOverviewView(dashboardViewModel: dashboardViewModel, navigation: navigation)
        case let .ecosystem(tap): EcosystemView(
                tap: Tap(name: tap),
                dashboardViewModel: dashboardViewModel,
                navigation: navigation
            )
        case .thirdPartyEcosystems: ThirdPartyEcosystemsView(dashboardViewModel: dashboardViewModel)
        case .searchResults: SearchResultsView(
                dashboardViewModel: dashboardViewModel,
                onClearSearch: { searchText = "" }
            )
        case .services: ServicesSection(viewModel: viewModel)
        case .doctorWarnings: DoctorWarningsSection(viewModel: viewModel, settingsViewModel: settingsViewModel)
        case .insights: InsightsSection(viewModel: viewModel)
        case .cache: CacheSection(dashboardViewModel: dashboardViewModel)
        case .diskUsage: DiskUsageSection(dashboardViewModel: dashboardViewModel)
        case .settings: SettingsPage(viewModel: settingsViewModel)
        }
    }
}

// MARK: - Shared empty state

/// `ContentUnavailableView` — the native macOS 14+ empty-state component — instead of
/// a hand-rolled centered `Text`, so every tool section (Services/Doctor/Insights/
/// Outdated) gets the same icon + title + description treatment Apple's own apps use.
@MainActor
private func emptyState(_ title: String, systemImage: String, description: String? = nil) -> some View {
    ScrollableEmptyState {
        ContentUnavailableView(title, systemImage: systemImage, description: description.map(Text.init))
    }
}

/// The shape shared by every Dashboard "Tools" section: empty state OR list, plus a
/// "title + count" `.navigationSubtitle` — Services/Doctor Warnings/Insights/Outdated
/// Packages differed only in row content, empty-state copy, and subtitle text.
private struct ToolSection<Content: View>: View {
    let isEmpty: Bool
    let emptyTitle: String
    let emptySystemImage: String
    let emptyDescription: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        // `Group`, not `VStack(spacing: 0)` — every other "empty state or List" screen
        // (EcosystemView, SearchResultsView, InstalledView) already makes
        // whichever branch renders the single top-level view, with no wrapper around
        // it. A `VStack` here, even with only one child, is still an extra layer
        // between the List and the toolbar-adjacent edge, which is what made Doctor
        // Warnings/Services/Insights/Outdated Packages compute their scroll-edge state
        // differently from every other section instead of the same way.
        Group {
            if isEmpty {
                emptyState(emptyTitle, systemImage: emptySystemImage, description: emptyDescription)
            } else {
                List { content }
                    .scrollContentBackground(.hidden)
            }
        }
        .navigationSubtitle(subtitle)
    }
}

// MARK: - Outdated Packages

private struct OutdatedPackagesSection: View {
    let viewModel: MenuBarViewModel
    // Only for the third-party-origin badge below — MenuBarViewModel has no
    // InstalledPackage/tap data of its own to answer that (see
    // DashboardViewModel.isOfficialOrigin's doc comment for why it's not grown one).
    let dashboardViewModel: DashboardViewModel
    @Environment(DashboardNavigation.self) private var navigation
    @State private var showingUpgradeConfirm = false
    /// Set by this page's own check buttons, so only the checks asked for here are announced.
    @State private var announcesCheck = false

    private var upgradeConfirmTitle: String {
        let count = viewModel.bulkUpgradeCount
        return count == 1 ? L("Upgrade 1 package?") : L("Upgrade \(count) packages?")
    }

    /// Names first, capped so a long list stays readable in the dialog.
    private var upgradeConfirmMessage: String {
        let names = MenuBarViewModel.bulkUpgradeTargets(viewModel.outdatedPackages).map(\.name)
        let shown = names.prefix(8).joined(separator: ", ")
        let more = names.count - 8
        let list = more > 0 ? "\(shown) \(L("and \(more) more"))" : shown
        return "\(L("Homebrew will upgrade: \(list)")) \(L("Some casks may ask for your password."))"
    }

    private var outdatedList: some View {
        // No repeated "Outdated Packages" text, and Upgrade All/Cancel now live in the
        // toolbar (see below) at title height, instead of a separate row well below
        // the native title.
        ToolSection(
            // A failed re-check isn't "up to date": the list shows the failure instead.
            isEmpty: viewModel.isUpToDate,
            emptyTitle: L("Up to date"),
            emptySystemImage: "checkmark.circle",
            emptyDescription: L("Every installed package is on its latest version."),
            subtitle: viewModel.updatesSubtitle
        ) {
            if let failure = viewModel.outdatedFailure {
                InlineError(message: failure)
            }
            // An upgrade that failed with its sheet not up — started from the menu bar, say, and
            // reached through the "Upgrade failed" notification, which used to land on a page
            // that said nothing about it.
            if let failure = viewModel.upgradeFailure, !navigation.showsUpgradeLog {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    InlineError(message: failure)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("Show Log")) { navigation.showsUpgradeLog = true }
                        .buttonStyle(.roomyBordered)
                        .controlSize(.small)
                }
            }
            // Inside the List (not above ToolSection) so the scroll-edge behavior stays
            // the same as every other tool section — see ToolSection's comment.
            ForEach(viewModel.outdatedPackages) { pkg in
                PackageRow(
                    package: pkg,
                    isUpgrading: viewModel.upgradingPackages.contains(pkg.name),
                    isDisabled: viewModel.isRunningAnyUpgrade,
                    isThirdParty: !dashboardViewModel.isOfficialOrigin(pkg.name),
                    failure: viewModel.upgradeFailure(forPackage: pkg.name),
                    onUpgrade: {
                        if viewModel.upgradePackage(pkg.name) { navigation.showsUpgradeLog = true }
                    }
                )
            }
        }
    }

    var body: some View {
        // "Up to date" only once a check has really happened — before that, or when it failed,
        // an empty list said so anyway (see `MenuBarViewModel.updatesPage`).
        Group {
            switch viewModel.updatesPage {
            case .running:
                LoadingView(label: L("Checking Homebrew…"), fillHeight: true)
            case let .failed(failure):
                RetryableErrorState(title: L("Couldn't check for updates"), message: failure) {
                    checkForUpdates()
                }
            case .notChecked:
                NotCheckedState(
                    systemImage: "arrow.down.app",
                    description: L("BrewMenu hasn't checked for updates since it started."),
                    actionTitle: L("Check for updates"),
                    action: checkForUpdates
                )
            case .checked:
                outdatedList
            }
        }
        .toolbar {
            // Its own item, apart from Upgrade All: inside the same one it shared Upgrade All's glass
            // capsule, which the prominent button tinted — one blue pill that read as one button.
            ToolbarItem(placement: .primaryAction) {
                // This page had no way to check again short of the menu bar.
                Button { checkForUpdates() } label: {
                    Label(
                        viewModel.isRefreshing ? L("Checking Homebrew…") : L("Check for updates"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(viewModel.isRefreshing || viewModel.isRunningAnyUpgrade)
                .keyboardShortcut("r", modifiers: .command)
                .help(L("Check for updates"))
            }
            // The toolbar puts neighbouring items on one glass background; the spacer starts a new one.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            // A single ToolbarItem with its own HStack — see EcosystemView for why:
            // separate items in a ToolbarItemGroup don't reliably get a gap between them.
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    if viewModel.isRunningAnyUpgrade {
                        ProgressView().controlSize(.small)
                        // One started from the menu bar runs with no sheet up: this is its log.
                        if !navigation.showsUpgradeLog {
                            Button(L("Show Log")) { navigation.showsUpgradeLog = true }
                                .buttonStyle(.roomyBordered)
                        }
                        Button(L("Cancel")) { viewModel.cancelUpgrade() }
                            .buttonStyle(.roomyBordered)
                            .disabled(viewModel.isCancellingUpgrade)
                    } else {
                        Button(L("Upgrade All")) { showingUpgradeConfirm = true }
                            .accessibilityIdentifier(AccessibilityID.upgradeAllButton)
                            .buttonStyle(.roomyBorderedProminent)
                            .disabled(viewModel.isRefreshing || viewModel.bulkUpgradeCount == 0)
                            .keyboardShortcut("u", modifiers: [.command, .shift])
                            .confirmationDialog(
                                upgradeConfirmTitle,
                                isPresented: $showingUpgradeConfirm,
                                titleVisibility: .visible
                            ) {
                                Button(L("Upgrade All")) {
                                    if viewModel.upgradeAll() { navigation.showsUpgradeLog = true }
                                }
                                Button(L("Cancel"), role: .cancel) {}
                            } message: {
                                Text(upgradeConfirmMessage)
                            }
                    }
                }
                // Room from the window's trailing edge — the toolbar's default
                // margin left it sitting almost flush against the corner.
                .padding(.trailing, 6)
            }
        }
        // A check asked for here changes the list in place: say what it found, or that it failed.
        // Not for the timer's checks, which would speak at random.
        .onChange(of: viewModel.isRefreshing) { _, refreshing in
            guard !refreshing, announcesCheck else { return }
            announcesCheck = false
            AccessibilityNotification.Announcement(viewModel.outdatedFailure ?? viewModel.updatesSubtitle).post()
        }
    }

    private func checkForUpdates() {
        announcesCheck = true
        viewModel.refresh()
    }
}

/// The upgrade popup — same shape as the package installer's log sheet: a status header
/// with Cancel while running and Done afterwards, the latest line, and the full log behind
/// "Show more". A failure keeps the reason on screen and opens the log automatically.
private struct UpgradeLogSheet: View {
    let viewModel: MenuBarViewModel
    let onRetry: () -> Void
    let onClose: () -> Void
    @State private var showDetails = false

    private var isRunning: Bool {
        viewModel.isRunningAnyUpgrade
    }

    private var phase: MenuBarViewModel.UpgradePhase {
        viewModel.upgradePhase
    }

    private var failure: String? {
        viewModel.upgradeFailure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    CommandSheetIcon(
                        package: phase == .running ? currentPackage : nil,
                        symbol: headerSymbol,
                        tint: headerTint,
                        store: viewModel.store
                    )
                    Text(headerTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    // While brew stops (it then re-reads the list, up to a couple of minutes), the
                    // sheet can be closed: the cancel goes on without it, and the window isn't held.
                    Button(phase == .running ? L("Cancel") : phase == .cancelling ? L("Close") : L("Done")) {
                        if phase == .running { viewModel.cancelUpgrade() } else { onClose() }
                    }
                    .buttonStyle(.roomyBordered)
                    .controlSize(.small)
                    .keyboardShortcut(phase == .running ? .cancelAction : .defaultAction)
                    .accessibilityIdentifier(AccessibilityID.upgradeSheetPrimary)
                }

                // What brew is doing, real figures only — the same as the install sheet's (see
                // `CommandRunMonitor`). Nothing printed yet while queued: waiting, not stuck.
                if isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        CommandRunProgress(
                            snapshot: viewModel.upgradeRun.snapshot(
                                at: context.date,
                                lastLine: viewModel.upgradeLog.last,
                                waiting: viewModel.upgradeLog.isEmpty && viewModel.isWaitingBehindBrew
                            )
                        )
                    }
                }

                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        Button(L("Copy error")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(viewModel.upgradeFailureDetails ?? failure, forType: .string)
                        }
                        .buttonStyle(.roomyBordered)
                        .controlSize(.small)
                        .accessibilityIdentifier(AccessibilityID.upgradeSheetCopyError)
                        AskAIMenu { AIPrompt.failedCommand(viewModel.upgradeFailureDetails ?? failure) }
                        // Retry only when it repeats what started the run — a single-package
                        // retry belongs to its own Update button, not to Upgrade All.
                        if viewModel.lastUpgradeWasAll, !isRunning {
                            Button(L("Retry")) { onRetry() }
                                .buttonStyle(.roomyBorderedProminent)
                                .controlSize(.small)
                                // Upgrade All waits out a check; a Retry then did nothing at all.
                                .disabled(viewModel.isRefreshing)
                                .accessibilityIdentifier(AccessibilityID.upgradeSheetRetry)
                        }
                    }
                }

                CommandLogDisclosureButton(showDetails: $showDetails)
            }
            .padding()

            if showDetails {
                CommandLogBox(lines: viewModel.upgradeLog)
            }
        }
        .frame(width: 480)
        // `initial`: the sheet can open on a failure already there ("Show Log").
        .onChange(of: failure != nil, initial: true) { _, failed in
            if failed { showDetails = true }
        }
        // The visual result is hard to notice for VoiceOver users, so say it out loud — the real
        // one: a cancelled run used to be announced as "Upgrade complete".
        .onChange(of: isRunning) { _, running in
            guard !running else { return }
            AccessibilityNotification.Announcement(phase == .done ? L("Upgrade complete") : headerTitle).post()
        }
        .onChange(of: phase == .cancelling) { _, cancelling in
            if cancelling { AccessibilityNotification.Announcement(L("Cancelling…")).post() }
        }
    }

    /// The package brew is on — the only one, or where Upgrade All has got to — once it's known.
    private var currentPackage: String? {
        viewModel.upgradeRun.position?.current
            ?? (viewModel.upgradeTargets.count == 1 ? viewModel.upgradeTargets.first : nil)
    }

    /// "Done" only for a run that worked — a cancelled one ended on it, with a green check.
    private var headerTitle: String {
        switch phase {
        case .running: currentPackage.map { L("Upgrading \($0)") } ?? L("Upgrading packages…")
        case .cancelling: L("Cancelling…")
        case .cancelled: L("Upgrade cancelled")
        // The packages brew said failed, when an Upgrade All went through for the rest.
        case .failed: switch viewModel.upgradeFailedPackages.count {
            case 0: L("Upgrade failed")
            case 1: L("Couldn't upgrade \(viewModel.upgradeFailedPackages[0])")
            default: L("Couldn't upgrade \(viewModel.upgradeFailedPackages.count) packages")
            }
        case .done: L("Done")
        }
    }

    private var headerSymbol: String {
        switch phase {
        case .running, .cancelling: "arrow.triangle.2.circlepath"
        case .cancelled: "stop.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    private var headerTint: Color {
        switch phase {
        case .running, .cancelling: BrewTheme.accent
        case .cancelled: .secondary
        case .failed: .red
        case .done: .green
        }
    }
}

// MARK: - Services

private struct ServicesSection: View {
    let viewModel: MenuBarViewModel

    var body: some View {
        // A failed start/stop used to show only in the popover, and a failed read as "no services".
        let failure = viewModel.servicesPageFailure
        ToolSection(
            isEmpty: viewModel.servicesFoundNothing,
            emptyTitle: L("No services found"),
            emptySystemImage: "gearshape.2",
            emptyDescription: L("Homebrew isn't managing any background services."),
            subtitle: viewModel.visibleServices
                .count == 1 ? L("1 service") : L("\(viewModel.visibleServices.count) services")
        ) {
            if let failure {
                InlineError(message: failure)
            }
            ForEach(viewModel.visibleServices) { entry in
                ServiceRow(
                    entry: entry,
                    isToggling: viewModel.togglingServices.contains(entry.name),
                    onStart: { viewModel.startService(entry.name) },
                    onStop: { viewModel.stopService(entry.name) }
                )
            }
        }
        // Services are only polled while the popover is open; this page would otherwise show
        // whatever the last poll saw.
        .task { await viewModel.refreshServices() }
        // The failure appears at the top of the list, away from the button that caused it.
        .onChange(of: viewModel.servicesPageFailure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure).post() }
        }
    }
}

// MARK: - Doctor Warnings

/// "No warnings" only once `brew doctor` has really run: before that (it starts at launch) or
/// after a first run that failed, the page says so — an empty list read as "all clear" either way.
private struct DoctorWarningsSection: View {
    let viewModel: MenuBarViewModel
    /// Where ignoring a finding is saved.
    let settingsViewModel: SettingsViewModel

    var body: some View {
        Group {
            switch viewModel.doctorPage {
            case .running:
                LoadingView(label: L("Running brew doctor…"), fillHeight: true)
            case let .failed(failure):
                RetryableErrorState(title: L("Couldn't run brew doctor"), message: failure) {
                    viewModel.runDoctor()
                }
            case .notChecked:
                NotCheckedState(
                    systemImage: "stethoscope",
                    description: L("brew doctor hasn't run since BrewMenu started."),
                    actionTitle: L("Run brew doctor"),
                    action: viewModel.runDoctor
                )
            case .checked:
                ToolSection(
                    isEmpty: viewModel.doctorFoundNothing,
                    emptyTitle: L("No warnings"),
                    emptySystemImage: "checkmark.seal",
                    emptyDescription: L("brew doctor didn't find any problems."),
                    subtitle: viewModel.doctorSubtitle
                ) {
                    if let failure = viewModel.doctorFailure {
                        InlineError(message: failure)
                    }
                    ForEach(viewModel.visibleDoctorWarnings) { warning in
                        DoctorWarningCard(warning: warning) {
                            settingsViewModel.ignoreDoctorWarning(titled: warning.title)
                            // The card leaves, and the button with it: say where it went.
                            AccessibilityNotification.Announcement(L("Ignored: \(warning.title)")).post()
                        }
                    }
                    if !viewModel.ignoredDoctorWarnings.isEmpty {
                        Section(L("Ignored")) {
                            ForEach(viewModel.ignoredDoctorWarnings) { warning in
                                IgnoredDoctorWarningRow(warning: warning) {
                                    settingsViewModel.stopIgnoringDoctorWarning(titled: warning.title)
                                    // The row leaves, and the button with it: say where it went.
                                    AccessibilityNotification.Announcement(
                                        L("No longer ignored: \(warning.title)")
                                    ).post()
                                }
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // One button that shows the run, not a spinner swapped in for it: a keyboard or
                // VoiceOver cursor on it would otherwise be dropped mid-check. Same width in both
                // states (see `BusyButtonLabel`), so the toolbar doesn't jump when a check starts.
                Button { viewModel.runDoctor() } label: {
                    BusyButtonLabel(
                        title: L("Check Again"),
                        busyTitle: L("Checking…"),
                        systemImage: "arrow.clockwise",
                        isBusy: viewModel.isRunningDoctor
                    )
                }
                .buttonStyle(.roomyBordered)
                .disabled(viewModel.isRunningDoctor)
                .keyboardShortcut("r", modifiers: .command)
                .help(L("Run brew doctor again"))
                .accessibilityLabel(viewModel.isRunningDoctor ? L("Running brew doctor…") : L("Check Again"))
                .padding(.trailing, 6)
            }
        }
        // The list changes in place; say what the check found — or that it failed.
        .onChange(of: viewModel.isRunningDoctor) { _, running in
            guard !running, viewModel.doctorPage == .checked else { return }
            AccessibilityNotification.Announcement(viewModel.doctorFailure ?? viewModel.doctorSubtitle).post()
        }
    }
}

// MARK: - Insights

private struct InsightsSection: View {
    let viewModel: MenuBarViewModel

    var body: some View {
        ToolSection(
            isEmpty: viewModel.insightsFoundNothing,
            emptyTitle: L("No insights"),
            emptySystemImage: "lightbulb",
            emptyDescription: L("Nothing to report right now."),
            subtitle: viewModel.insights.count == 1 ? L("1 insight") : L("\(viewModel.insights.count) insights")
        ) {
            // Clean Up and Remove run from here; their failure used to show only in the popover.
            if let failure = viewModel.maintenanceFailure {
                InlineError(message: failure)
            }
            ForEach(viewModel.insights) { insight in
                InsightRow(insight: insight, viewModel: viewModel)
                    .padding(.vertical, 4)
            }
        }
        // Same as Services: the failure appears at the top, away from the button that ran it.
        .onChange(of: viewModel.maintenanceFailure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure).post() }
        }
    }
}

// MARK: - Cache

private struct CacheSection: View {
    let dashboardViewModel: DashboardViewModel

    @State private var showingClearConfirmation = false

    private var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: dashboardViewModel.totalCacheBytes, countStyle: .file)
    }

    var body: some View {
        Group {
            // Only for the first load (nothing on screen yet) — once there's a list,
            // a delete/clear in flight updates it in place instead of blanking it.
            if dashboardViewModel.isLoadingCache, dashboardViewModel.cacheEntries.isEmpty {
                LoadingView()
            } else if dashboardViewModel.cacheEntries.isEmpty, let error = dashboardViewModel.cacheError {
                // A failed read must not look like an empty cache ("nothing to clear").
                RetryableErrorState(title: L("Couldn't load cache"), message: error) {
                    Task { await dashboardViewModel.loadCacheEntries() }
                }
            } else {
                ToolSection(
                    isEmpty: dashboardViewModel.cacheEntries.isEmpty,
                    emptyTitle: L("No cached downloads"),
                    emptySystemImage: "archivebox",
                    emptyDescription: L("Homebrew's download cache is empty."),
                    subtitle: dashboardViewModel.cacheEntries.count == 1
                        ? L("1 file · \(formattedTotal)")
                        : L("\(dashboardViewModel.cacheEntries.count) files · \(formattedTotal)")
                ) {
                    if let error = dashboardViewModel.cacheError {
                        InlineError(message: error)
                    }
                    ForEach(dashboardViewModel.cacheEntries) { entry in
                        CacheEntryRow(entry: entry, dashboardViewModel: dashboardViewModel)
                    }
                }
            }
        }
        .task { await dashboardViewModel.loadCacheEntries() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(L("Clear Cache")) { showingClearConfirmation = true }
                    .buttonStyle(.roomyBordered)
                    .disabled(dashboardViewModel.cacheEntries.isEmpty || dashboardViewModel.isLoadingCache)
                    .confirmationDialog(
                        L("Clear the Homebrew download cache?"),
                        isPresented: $showingClearConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(L("Clear Cache"), role: .destructive) {
                            Task { await dashboardViewModel.clearCache() }
                        }
                        Button(L("Cancel"), role: .cancel) {}
                    } message: {
                        Text(
                            L(
                                "Deletes every cached download (\(formattedTotal)). Homebrew re-downloads anything it needs again."
                            )
                        )
                    }
            }
        }
    }
}

private struct CacheEntryRow: View {
    let entry: CacheEntry
    let dashboardViewModel: DashboardViewModel

    @State private var showingDeleteConfirmation = false
    @State private var isHoveringTrash = false
    @FocusState private var trashFocused: Bool

    private var isDeleting: Bool {
        dashboardViewModel.deletingCacheEntryIDs.contains(entry.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: entry.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                .font(.caption)
                .foregroundStyle(entry.sizeBytes.diskUsageTintColor)
                .monospacedDigit()

            if isDeleting {
                ProgressView().controlSize(.small)
                    .frame(minWidth: 24, minHeight: 24)
                    .accessibilityLabel(L("Deleting \(entry.name)"))
            } else {
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isHoveringTrash || trashFocused ? .red : .secondary)
                .focused($trashFocused)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
                .onHover { isHoveringTrash = $0 }
                .accessibilityLabel(L("Delete \(entry.name)"))
                .confirmationDialog(
                    L("Delete \(entry.name)?"),
                    isPresented: $showingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(L("Delete"), role: .destructive) {
                        Task { await dashboardViewModel.deleteCacheEntry(entry) }
                    }
                    Button(L("Cancel"), role: .cancel) {}
                } message: {
                    Text(L("Homebrew re-downloads this if it's needed again."))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Disk usage size coloring (view layer, shared by Cache/Disk Usage/Unused Dependencies)

private extension Int64 {
    /// A simple three-tier heatmap so the biggest space users pop out while
    /// scanning a list, instead of reading every byte count in turn: red above
    /// 1 GB, orange above 250 MB, plain otherwise.
    var diskUsageTintColor: Color {
        let oneGB: Int64 = 1_073_741_824
        let quarterGB: Int64 = 262_144_000
        if self >= oneGB { return .red }
        if self >= quarterGB { return .orange }
        return .secondary
    }
}

// MARK: - Disk Usage

private struct DiskUsageSection: View {
    let dashboardViewModel: DashboardViewModel

    private var totalBytes: Int64 {
        dashboardViewModel.packageDiskUsage.reduce(0) { $0 + $1.sizeBytes }
    }

    private var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var body: some View {
        Group {
            if dashboardViewModel.isLoadingDiskUsage, dashboardViewModel.packageDiskUsage.isEmpty {
                LoadingView()
            } else if dashboardViewModel.packageDiskUsage.isEmpty, let error = dashboardViewModel.diskUsageError {
                RetryableErrorState(title: L("Couldn't measure disk usage"), message: error) {
                    Task { await dashboardViewModel.loadDiskUsage() }
                }
            } else {
                ToolSection(
                    isEmpty: dashboardViewModel.packageDiskUsage.isEmpty,
                    emptyTitle: L("Nothing installed"),
                    emptySystemImage: "internaldrive",
                    emptyDescription: L("No installed packages to size up."),
                    subtitle: dashboardViewModel.packageDiskUsage.count == 1
                        ? L("1 package · \(formattedTotal)")
                        : L("\(dashboardViewModel.packageDiskUsage.count) packages · \(formattedTotal)")
                ) {
                    if let error = dashboardViewModel.diskUsageError {
                        InlineError(message: error)
                    }
                    ForEach(dashboardViewModel.packageDiskUsage) { entry in
                        DiskUsageRow(entry: entry, dashboardViewModel: dashboardViewModel)
                    }
                }
            }
        }
        .task { await dashboardViewModel.loadDiskUsage() }
    }
}

private struct DiskUsageRow: View {
    let entry: PackageDiskUsage
    let dashboardViewModel: DashboardViewModel

    @State private var showingDeleteConfirmation = false
    @State private var isHoveringTrash = false
    @FocusState private var trashFocused: Bool

    private var isUninstalling: Bool {
        dashboardViewModel.uninstallingNames.contains(entry.name)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: entry.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            // Formula vs. cask isn't visible from the name alone (unlike Cache's
            // filenames), and it matters here — it's the difference between a CLI
            // tool and a whole app bundle.
            Text(entry.isCask ? L("Cask") : L("Formula"))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                .font(.caption)
                .foregroundStyle(entry.sizeBytes.diskUsageTintColor)
                .monospacedDigit()

            if isUninstalling {
                ProgressView().controlSize(.small)
                    .frame(minWidth: 24, minHeight: 24)
                    .accessibilityLabel(L("Uninstalling \(entry.name)"))
            } else {
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isHoveringTrash || trashFocused ? .red : .secondary)
                .focused($trashFocused)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
                .onHover { isHoveringTrash = $0 }
                .accessibilityLabel(L("Uninstall \(entry.name)"))
                .uninstallConfirmation(
                    isPresented: $showingDeleteConfirmation,
                    name: entry.name,
                    dependents: dashboardViewModel.installedDependents(of: entry.name)
                ) {
                    Task { await dashboardViewModel.uninstallFromDiskUsage(entry) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
