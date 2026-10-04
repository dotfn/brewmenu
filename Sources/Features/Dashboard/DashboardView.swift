import AppKit
import SwiftUI

struct DashboardView: View {
    let viewModel: MenuBarViewModel
    let settingsViewModel: SettingsViewModel
    @Bindable var dashboardViewModel: DashboardViewModel
    @Bindable var navigation: DashboardNavigation

    // A plain @State backing .searchable, rather than a computed Binding straight to the
    // view model — a get/set Binding here was silently breaking onSubmit(of: .search) on
    // macOS (typing and picking a suggestion worked, but pressing Return did nothing).
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
                        Label(section.title, systemImage: section.systemImage).tag(section)
                    }
                }
                Section(L("Ecosystems")) {
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
                if !dashboardViewModel.activeCategories.isEmpty {
                    Section(L("Categories")) {
                        ForEach(dashboardViewModel.activeCategories) { category in
                            // A composed row instead of .badge(): .badge() on a sidebar row
                            // inside a NavigationSplitView's List(selection:) can swallow the
                            // row's tap, leaving selection stuck (confirmed — Ecosystems rows,
                            // which have no .badge(), select fine; these didn't).
                            HStack {
                                Label(category.title, systemImage: category.systemImage)
                                Spacer()
                                Text("\(dashboardViewModel.count(in: category))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .tag(DashboardSection.category(category))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(L("\(category.title), \(dashboardViewModel.count(in: category)) packages"))
                        }
                    }
                }
                Section(L("Tools")) {
                    ForEach(DashboardSection.toolSections, id: \.self) { section in
                        Label(section.title, systemImage: section.systemImage).tag(section)
                    }
                }
                Section(L("Settings")) {
                    ForEach(DashboardSection.settingsSections, id: \.self) { section in
                        Label(section.title, systemImage: section.systemImage).tag(section)
                    }
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
                detailContent
            }
            .navigationTitle(navigation.selectedSection.title)
        }
        // Lets the reusable browse-row family (PackageBrowseRow/PackageStatusIndicator/
        // PackageInfoButton/InstalledStatusButton in StatusBadge.swift) read
        // DashboardViewModel from the environment instead of having it re-threaded through
        // every intermediate view purely to reach those leaves. Applied here (outside the
        // NavigationSplitView, not nested inside `detail:`) so it also reaches the sheets
        // below — a `.environment(...)` scoped only to `detail:`'s content would not
        // propagate to `.sheet(...)`, which presents outside that subtree.
        .environment(dashboardViewModel)
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
        .task { await settingsViewModel.load() }
        .task { await dashboardViewModel.load() }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
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
            navigation.isWindowOpen = false
            navigation.forceShowIcon = false
        }
        .sheet(item: $dashboardViewModel.selectedPackageDetailTarget) { target in
            PackageDetailView(target: target, dashboardViewModel: dashboardViewModel)
        }
        .sheet(isPresented: Binding(
            get: { dashboardViewModel.isInstalling },
            // A real setter — without one, Esc/click-outside couldn't dismiss this sheet
            // at all. Routes through `dismissInstallSheet()` so an install still in
            // flight gets stopped rather than left running with no UI attached to it.
            set: { isPresented in if !isPresented { dashboardViewModel.dismissInstallSheet() } }
        )) {
            InstallLogView(dashboardViewModel: dashboardViewModel)
                .interactiveDismissDisabled(dashboardViewModel.isInstallRunning)
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
            Button(L("OK")) { dashboardViewModel.uninstallFailureAlertName = nil }
        } message: {
            Text(dashboardViewModel.uninstallErrors[dashboardViewModel.uninstallFailureAlertName ?? ""] ?? "")
        }
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
        case .installed: InstalledView(dashboardViewModel: dashboardViewModel)
        case .outdatedPackages: OutdatedPackagesSection(viewModel: viewModel)
        case .installPacks: InstallPacksView(dashboardViewModel: dashboardViewModel)
        case .recommendedTaps: RecommendedTapsView(dashboardViewModel: dashboardViewModel)
        case .ecosystemsOverview: EcosystemsOverviewView(dashboardViewModel: dashboardViewModel, navigation: navigation)
        case .ecosystem(let tap): EcosystemView(tap: Tap(name: tap), dashboardViewModel: dashboardViewModel, navigation: navigation)
        case .thirdPartyEcosystems: ThirdPartyEcosystemsView(dashboardViewModel: dashboardViewModel)
        case .category(let category): CategoryView(category: category, dashboardViewModel: dashboardViewModel)
        case .searchResults: SearchResultsView(dashboardViewModel: dashboardViewModel, onClearSearch: { searchText = "" })
        case .services: ServicesSection(viewModel: viewModel)
        case .doctorWarnings: DoctorWarningsSection(viewModel: viewModel)
        case .insights: InsightsSection(viewModel: viewModel)
        case .cache: CacheSection(dashboardViewModel: dashboardViewModel)
        case .diskUsage: DiskUsageSection(dashboardViewModel: dashboardViewModel)
        case .general: GeneralTab(viewModel: settingsViewModel)
        case .notifications: NotificationsTab(viewModel: settingsViewModel)
        case .about: AboutTab()
        }
    }
}

// MARK: - Shared empty state

/// `ContentUnavailableView` — the native macOS 14+ empty-state component — instead of
/// a hand-rolled centered `Text`, so every tool section (Services/Doctor/Insights/
/// Outdated) gets the same icon + title + description treatment Apple's own apps use.
@MainActor @ViewBuilder
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
    let content: Content

    init(
        isEmpty: Bool,
        emptyTitle: String,
        emptySystemImage: String,
        emptyDescription: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.isEmpty = isEmpty
        self.emptyTitle = emptyTitle
        self.emptySystemImage = emptySystemImage
        self.emptyDescription = emptyDescription
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        // `Group`, not `VStack(spacing: 0)` — every other "empty state or List" screen
        // (CategoryView, EcosystemView, SearchResultsView, InstalledView) already makes
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
    @State private var showingUpgradeSheet = false
    @State private var showingUpgradeConfirm = false

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

    var body: some View {
        // No repeated "Outdated Packages" text, and Upgrade All/Cancel now live in the
        // toolbar (see below) at title height, instead of a separate row well below
        // the native title.
        ToolSection(
            isEmpty: viewModel.outdatedPackages.isEmpty,
            emptyTitle: L("Up to date"),
            emptySystemImage: "checkmark.circle",
            emptyDescription: L("Every installed package is on its latest version."),
            subtitle: viewModel.isUpgrading ? L("Upgrading…") : (viewModel.outdatedPackages.count == 1 ? L("1 upgrade available") : L("\(viewModel.outdatedPackages.count) upgrades available"))
        ) {
            // Inside the List (not above ToolSection) so the scroll-edge behavior stays
            // the same as every other tool section — see ToolSection's comment.
            ForEach(viewModel.outdatedPackages) { pkg in
                PackageRow(
                    package: pkg,
                    isUpgrading: viewModel.upgradingPackages.contains(pkg.name),
                    isDisabled: viewModel.isUpgrading,
                    onUpgrade: {
                        showingUpgradeSheet = true
                        viewModel.upgradePackage(pkg.name)
                    }
                )
            }
        }
        .toolbar {
            // A single ToolbarItem with its own HStack — see EcosystemView for why:
            // separate items in a ToolbarItemGroup don't reliably get a gap between them.
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    if viewModel.isUpgrading {
                        ProgressView().controlSize(.small)
                        Button(L("Cancel")) { viewModel.cancelUpgrade() }
                            .buttonStyle(.bordered)
                    } else {
                        Button(L("Upgrade All")) { showingUpgradeConfirm = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isRefreshing || viewModel.bulkUpgradeCount == 0)
                            .keyboardShortcut("u", modifiers: [.command, .shift])
                            .confirmationDialog(
                                upgradeConfirmTitle,
                                isPresented: $showingUpgradeConfirm,
                                titleVisibility: .visible
                            ) {
                                Button(L("Upgrade All")) {
                                    showingUpgradeSheet = true
                                    viewModel.upgradeAll()
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
        // Same pattern as the package installer: stays open after the run so the result
        // and log can be read, closed by an explicit Done. Can't be dismissed mid-run.
        .sheet(isPresented: $showingUpgradeSheet) {
            UpgradeLogSheet(viewModel: viewModel, onRetry: { viewModel.upgradeAll() }) {
                showingUpgradeSheet = false
                viewModel.clearUpgradeFailure()
            }
            .interactiveDismissDisabled(viewModel.isUpgrading)
        }
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

    private var isRunning: Bool { viewModel.isUpgrading }
    private var failure: String? { viewModel.upgradeFailure }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if isRunning {
                        Text(L("Upgrading packages…"))
                            .font(.headline)
                        ProgressView().controlSize(.small)
                    } else if failure != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(L("Upgrade failed"))
                            .font(.headline)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(L("Done"))
                            .font(.headline)
                    }
                    Spacer()
                    Button(isRunning ? L("Cancel") : L("Done")) {
                        if isRunning { viewModel.cancelUpgrade() } else { onClose() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(isRunning ? .cancelAction : .defaultAction)
                }

                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        Button(L("Copy error")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(failure, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        // Retry only when it repeats what started the run — a single-package
                        // retry belongs to its own Update button, not to Upgrade All.
                        if viewModel.lastUpgradeWasAll && !isRunning {
                            Button(L("Retry")) { onRetry() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                } else if isRunning {
                    Text(verbatim: viewModel.upgradeLog.last ?? L("Starting upgrade…"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button {
                    showDetails.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(showDetails ? L("Hide details") : L("Show more"))
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            if showDetails {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(viewModel.upgradeLog.enumerated()), id: \.offset) { index, line in
                                Text(verbatim: line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: viewModel.upgradeLog.count) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
                .frame(height: 300)
            }
        }
        .frame(width: 480)
        .onChange(of: failure != nil) { _, failed in
            if failed { showDetails = true }
        }
        // The visual result is hard to notice for VoiceOver users, so say it out loud.
        .onChange(of: isRunning) { _, running in
            guard !running else { return }
            AccessibilityNotification.Announcement(failure == nil ? L("Upgrade complete") : L("Upgrade failed")).post()
        }
    }
}

// MARK: - Services

private struct ServicesSection: View {
    let viewModel: MenuBarViewModel

    var body: some View {
        ToolSection(
            isEmpty: viewModel.visibleServices.isEmpty,
            emptyTitle: L("No services found"),
            emptySystemImage: "gearshape.2",
            emptyDescription: L("Homebrew isn't managing any background services."),
            subtitle: viewModel.visibleServices.count == 1 ? L("1 service") : L("\(viewModel.visibleServices.count) services")
        ) {
            ForEach(viewModel.visibleServices) { entry in
                ServiceRow(
                    entry: entry,
                    isToggling: viewModel.togglingServices.contains(entry.name),
                    onStart: { viewModel.startService(entry.name) },
                    onStop: { viewModel.stopService(entry.name) }
                )
            }
        }
    }
}

// MARK: - Doctor Warnings

private struct DoctorWarningsSection: View {
    let viewModel: MenuBarViewModel

    var body: some View {
        ToolSection(
            isEmpty: viewModel.doctorWarnings.isEmpty,
            emptyTitle: L("No warnings"),
            emptySystemImage: "checkmark.seal",
            emptyDescription: L("brew doctor didn't find any problems."),
            subtitle: viewModel.doctorWarnings.count == 1 ? L("1 doctor warning") : L("\(viewModel.doctorWarnings.count) doctor warnings")
        ) {
            ForEach(viewModel.doctorWarnings) { warning in
                DoctorWarningRow(warning: warning)
                    .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Insights

private struct InsightsSection: View {
    let viewModel: MenuBarViewModel

    var body: some View {
        ToolSection(
            isEmpty: viewModel.insights.isEmpty,
            emptyTitle: L("No insights"),
            emptySystemImage: "lightbulb",
            emptyDescription: L("Nothing to report right now."),
            subtitle: viewModel.insights.count == 1 ? L("1 insight") : L("\(viewModel.insights.count) insights")
        ) {
            ForEach(viewModel.insights) { insight in
                InsightRow(insight: insight, viewModel: viewModel)
                    .padding(.vertical, 4)
            }
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
            if dashboardViewModel.isLoadingCache && dashboardViewModel.cacheEntries.isEmpty {
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
                    .buttonStyle(.bordered)
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
                        Text(L("Deletes every cached download (\(formattedTotal)). Homebrew re-downloads anything it needs again."))
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

    private var isDeleting: Bool { dashboardViewModel.deletingCacheEntryIDs.contains(entry.id) }

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

    private var totalBytes: Int64 { dashboardViewModel.packageDiskUsage.reduce(0) { $0 + $1.sizeBytes } }
    private var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var body: some View {
        Group {
            if dashboardViewModel.isLoadingDiskUsage && dashboardViewModel.packageDiskUsage.isEmpty {
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

    private var isUninstalling: Bool { dashboardViewModel.uninstallingNames.contains(entry.name) }

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
                .confirmationDialog(
                    L("Uninstall \(entry.name)?"),
                    isPresented: $showingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(L("Uninstall"), role: .destructive) {
                        Task { await dashboardViewModel.uninstallFromDiskUsage(entry) }
                    }
                    Button(L("Cancel"), role: .cancel) {}
                } message: {
                    Text(L("This removes \(entry.name) from your Mac. You can reinstall it anytime."))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

