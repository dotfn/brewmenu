import SwiftUI

struct InstalledView: View {
    let dashboardViewModel: DashboardViewModel

    private enum Filter: Hashable { case all, formulae, casks }

    @State private var filter: Filter = .all
    @State private var searchText: String = ""

    private var filteredPackages: [InstalledPackage] {
        dashboardViewModel.installedPackages
            .filter { pkg in
                switch filter {
                case .all: true
                case .formulae: !pkg.isCask
                case .casks: pkg.isCask
                }
            }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
            .sorted { $0.name < $1.name }
    }

    /// Names which active filter(s) produced an empty result — a bare "No packages
    /// found" didn't say whether that was the segmented filter, the search text, or
    /// (having installed nothing at all in that category) neither.
    private var emptyStateMessage: String {
        switch (filter, searchText.isEmpty) {
        case (.all, true): L("No packages found")
        case (.all, false): L("No results for \"\(searchText)\"")
        case (_, true): L("No \(filterName) installed")
        case (_, false): L("No \(filterName) match \"\(searchText)\"")
        }
    }

    private var filterName: String {
        switch filter {
        case .all: L("packages")
        case .formulae: L("formulae")
        case .casks: L("casks")
        }
    }

    /// Matches the state the empty view is explaining: a search in progress always
    /// wins (that's what's producing zero results), otherwise it's the segmented
    /// filter's own icon.
    private var emptyStateSystemImage: String {
        guard searchText.isEmpty else { return "magnifyingglass" }
        switch filter {
        case .all: return "shippingbox"
        case .formulae: return "terminal"
        case .casks: return "app.badge"
        }
    }

    var body: some View {
        let packages = filteredPackages
        // The List is the single top-level view — no more custom search row above it.
        // A hand-built `SearchField` living in a `.safeAreaInset` used to render as its
        // own opaque bar sitting right under the toolbar; once macOS started floating
        // the toolbar's own controls (the All/Formulae/Casks picker) as a Liquid Glass
        // pill above the content, that custom bar visually collided with it instead of
        // sitting cleanly below. `.searchable(placement: .toolbar)` is the native
        // macOS pattern for exactly this (a local, live-filter field next to other
        // toolbar controls — see Finder's own search field) — it renders inside the
        // same toolbar/glass surface the picker already uses, so there's nothing left
        // to collide. It also finishes what the last pass started: the List now truly
        // owns the toolbar-adjacent edge with zero inset content pushing on it, the
        // same shape every other list-backed section has.
        Group {
            if dashboardViewModel.isLoading {
                // Distinguishes "still loading" from a genuine empty result — without
                // this, the very first frame after opening the Dashboard (before
                // waitUntilConfigured()/load() resolve) rendered the same "No packages
                // found" empty state as a machine with nothing installed.
                LoadingView()
            } else if packages.isEmpty {
                ScrollableEmptyState {
                    ContentUnavailableView {
                        Label(emptyStateMessage, systemImage: emptyStateSystemImage)
                    } actions: {
                        if filter != .all || !searchText.isEmpty {
                            Button(L("Clear filters")) {
                                filter = .all
                                searchText = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                List(packages) { pkg in
                    InstalledPackageRow(package: pkg, dashboardViewModel: dashboardViewModel)
                }
                .scrollContentBackground(.hidden)
            }
        }
        // This screen's own local, live-as-you-type filter over the already-loaded
        // installed list — distinct from the Dashboard's global `.searchable` on the
        // sidebar (DashboardView.swift), which searches all of Homebrew and submits
        // over the network. Nested `.searchable` modifiers scope to whichever
        // destination is currently visible, so this one only takes over the detail
        // toolbar while Installed is showing and never touches the sidebar's own
        // search state or its submit/navigate-to-results behavior.
        .searchable(text: $searchText, placement: .toolbar, prompt: L("Search package…"))
        // Same "title + count" header shape as every other list-backed section
        // (Ecosystems, Categories, Third-Party) — this one used to be the odd one
        // out with just a bare title and no subtitle.
        .navigationSubtitle(packages.count == 1 ? L("1 package") : L("\(packages.count) packages"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("", selection: $filter) {
                    Text(L("All")).tag(Filter.all)
                    Text(L("Formulae")).tag(Filter.formulae)
                    Text(L("Casks")).tag(Filter.casks)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(L("Filter by package type"))
                .frame(width: 240)
            }
        }
    }
}
