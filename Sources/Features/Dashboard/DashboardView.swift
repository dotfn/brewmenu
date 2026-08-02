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

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selectedSection) {
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
                // While searching, give the sidebar a real highlighted "you are here" row —
                // without this, selecting .searchResults left every sidebar row unselected,
                // so users lost their place and had no visible in-sidebar way back.
                if navigation.selectedSection == .searchResults {
                    Section {
                        Label(L("Search Results"), systemImage: "magnifyingglass")
                            .tag(DashboardSection.searchResults)
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
            detailContent
                .navigationTitle(navigation.selectedSection.title)
        }
        // The MenuBar popover already shows this banner, but a user who upgrades BrewMenu
        // itself from the Dashboard's Outdated Packages list (rather than the popover)
        // might never open the popover again and would otherwise never learn a restart
        // is needed.
        .safeAreaInset(edge: .top) {
            if viewModel.needsRestart {
                restartBanner
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: L("Search Homebrew…"))
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
        .frame(minWidth: 700, minHeight: 450)
        // `.automatic` titlebar separator only draws once content scrolls out from
        // under the toolbar — showing up on some sections' first frame and not
        // others', and disappearing again at the top of a scroll. Forcing it off
        // keeps every section's header identical regardless of scroll position.
        .background(TitlebarSeparatorHider())
        .task { await settingsViewModel.load() }
        .task { await dashboardViewModel.load() }
        .onChange(of: settingsViewModel.settings) { _, _ in
            Task { await settingsViewModel.save() }
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            navigation.isWindowOpen = true
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
    }

    private func runSearch(_ query: String) {
        searchText = query
        navigation.selectedSection = .searchResults
        Task { await dashboardViewModel.commitSearch(query) }
    }

    private var restartBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .foregroundStyle(.orange)
            // Same size as the popover's identical banner (MenuBarView) — same
            // message, same weight, regardless of which window shows it.
            Text(L("BrewMenu updated — restart to apply"))
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            Button(L("Restart")) { AppRelauncher.restart() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
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
@ViewBuilder
private func emptyState(_ title: String, systemImage: String, description: String? = nil) -> some View {
    ContentUnavailableView(title, systemImage: systemImage, description: description.map(Text.init))
}

// MARK: - Outdated Packages

private struct OutdatedPackagesSection: View {
    let viewModel: MenuBarViewModel

    var body: some View {
        // No repeated "Outdated Packages" text, and Upgrade All/Cancel now live in the
        // toolbar (see below) at title height, instead of a separate row well below
        // the native title.
        Group {
            if viewModel.outdatedPackages.isEmpty {
                emptyState(
                    L("Up to date"),
                    systemImage: "checkmark.circle",
                    description: L("Every installed package is on its latest version.")
                )
            } else {
                List(viewModel.outdatedPackages) { pkg in
                    PackageRow(
                        package: pkg,
                        isUpgrading: viewModel.upgradingPackages.contains(pkg.name),
                        onUpgrade: { viewModel.upgradePackage(pkg.name) }
                    )
                }
                .scrollContentBackground(.hidden)
            }
        }
        // Same "title + count" header shape as every other list-backed section.
        .navigationSubtitle(viewModel.outdatedPackages.count == 1 ? L("1 update available") : L("\(viewModel.outdatedPackages.count) updates available"))
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
        // No header here — the window's navigationTitle already reads "Services"
        // immediately above; a bare bold copy of the same word had nothing else in it.
        VStack(spacing: 0) {
            if viewModel.visibleServices.isEmpty {
                emptyState(
                    L("No services found"),
                    systemImage: "gearshape.2",
                    description: L("Homebrew isn't managing any background services.")
                )
            } else {
                List(viewModel.visibleServices) { entry in
                    ServiceRow(
                        entry: entry,
                        isToggling: viewModel.togglingServices.contains(entry.name),
                        onStart: { viewModel.startService(entry.name) },
                        onStop: { viewModel.stopService(entry.name) }
                    )
                }
                .scrollContentBackground(.hidden)
            }
        }
        // Same "title + count" header shape as every other list-backed section.
        .navigationSubtitle(viewModel.visibleServices.count == 1 ? L("1 service") : L("\(viewModel.visibleServices.count) services"))
    }
}

// MARK: - Doctor Warnings

private struct DoctorWarningsSection: View {
    let viewModel: MenuBarViewModel

    var body: some View {
        // No header here — the window's navigationTitle already reads "Doctor Warnings"
        // immediately above.
        VStack(spacing: 0) {
            if viewModel.doctorWarnings.isEmpty {
                emptyState(
                    L("No warnings"),
                    systemImage: "checkmark.seal",
                    description: L("brew doctor didn't find any problems.")
                )
            } else {
                List(viewModel.doctorWarnings) { warning in
                    DoctorWarningRow(warning: warning)
                        .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }
        }
        // Same "title + count" header shape as every other list-backed section.
        .navigationSubtitle(viewModel.doctorWarnings.count == 1 ? L("1 doctor warning") : L("\(viewModel.doctorWarnings.count) doctor warnings"))
    }
}

// MARK: - Insights

private struct InsightsSection: View {
    let viewModel: MenuBarViewModel

    var body: some View {
        // No header here — the window's navigationTitle already reads "Insights"
        // immediately above.
        VStack(spacing: 0) {
            if viewModel.insights.isEmpty {
                emptyState(
                    L("No insights"),
                    systemImage: "lightbulb",
                    description: L("Nothing to report right now.")
                )
            } else {
                List(viewModel.insights) { insight in
                    InsightRow(insight: insight, viewModel: viewModel)
                        .padding(.vertical, 4)
                }
                .scrollContentBackground(.hidden)
            }
        }
        // Same "title + count" header shape as every other list-backed section.
        .navigationSubtitle(viewModel.insights.count == 1 ? L("1 insight") : L("\(viewModel.insights.count) insights"))
    }
}

// MARK: - TitlebarSeparatorHider

/// Reaches into the hosting `NSWindow` to force `titlebarSeparatorStyle = .none`.
/// `NavigationSplitView` is backed by an `NSSplitViewController`, and each pane's
/// `NSSplitViewItem` carries its *own* separator style independent of the window's —
/// setting only `window.titlebarSeparatorStyle` (the first attempt at this) left the
/// detail pane's own separator untouched, which is why the line was still showing.
private struct TitlebarSeparatorHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SeparatorHidingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SeparatorHidingView)?.applySeparatorStyle()
    }
}

private final class SeparatorHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySeparatorStyle()
    }

    func applySeparatorStyle() {
        guard let window else { return }
        window.titlebarSeparatorStyle = .none
        if let splitViewController = window.contentViewController as? NSSplitViewController {
            for item in splitViewController.splitViewItems {
                item.titlebarSeparatorStyle = .none
            }
        }
    }
}
