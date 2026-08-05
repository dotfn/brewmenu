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
        .onChange(of: settingsViewModel.settings) { _, _ in
            Task { await settingsViewModel.save() }
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            navigation.isWindowOpen = true
            dashboardViewModel.updateLiveOutdatedNames(Set(viewModel.outdatedPackages.map(\.name)))
            // Seeds `sidebarSelection` for the case where `navigation.selectedSection`
            // was already set to something other than `.home` before this view ever
            // appeared — e.g. a menu bar notification's "open dashboard to X" — which
            // the `onChange` above can't catch since nothing changed after that point.
            if navigation.selectedSection != .searchResults {
                sidebarSelection = navigation.selectedSection
            }
        }
        // `viewModel.outdatedPackages` (from `brew outdated`, refreshed by StatusChecker
        // in the background) is the same source the popover and the Outdated Packages
        // section already trust — keeping DashboardViewModel's copy in sync is what keeps
        // Home's "Outdated" stat card and the Installed list's badges from disagreeing
        // with it (see `DashboardViewModel.liveOutdatedNames`).
        .onChange(of: viewModel.outdatedPackages.map(\.name)) { _, names in
            dashboardViewModel.updateLiveOutdatedNames(Set(names))
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

    var body: some View {
        // No repeated "Outdated Packages" text, and Upgrade All/Cancel now live in the
        // toolbar (see below) at title height, instead of a separate row well below
        // the native title.
        ToolSection(
            isEmpty: viewModel.outdatedPackages.isEmpty,
            emptyTitle: L("Up to date"),
            emptySystemImage: "checkmark.circle",
            emptyDescription: L("Every installed package is on its latest version."),
            subtitle: viewModel.outdatedPackages.count == 1 ? L("1 update available") : L("\(viewModel.outdatedPackages.count) updates available")
        ) {
            ForEach(viewModel.outdatedPackages) { pkg in
                PackageRow(
                    package: pkg,
                    isUpgrading: viewModel.upgradingPackages.contains(pkg.name),
                    onUpgrade: { viewModel.upgradePackage(pkg.name) }
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
                        Button(L("Upgrade All")) { viewModel.upgradeAll() }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isRefreshing || viewModel.outdatedPackages.isEmpty)
                            .keyboardShortcut("u", modifiers: [.command, .shift])
                    }
                }
                // Room from the window's trailing edge — the toolbar's default
                // margin left it sitting almost flush against the corner.
                .padding(.trailing, 6)
            }
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

