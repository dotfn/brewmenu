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
        VStack(spacing: 0) {
            // No repeated "Installed" text, and the All/Formulae/Casks filter now lives
            // in the toolbar (see below) at title height, instead of floating alone in
            // its own row well below the native title.
            //
            // A filled, rounded field (not bare text on the background) — without a
            // visible boundary this read as static text, not something you could click
            // into. The field itself now provides the visual separation from the list
            // below, so the old full-bleed Divider() underneath is gone too.
            searchField
                .padding(.horizontal)
                .padding(.vertical, 8)

            if dashboardViewModel.isLoading {
                // Distinguishes "still loading" from a genuine empty result — without
                // this, the very first frame after opening the Dashboard (before
                // waitUntilConfigured()/load() resolve) rendered the same "No packages
                // found" empty state as a machine with nothing installed.
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if packages.isEmpty {
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
            } else {
                List(packages) { pkg in
                    InstalledPackageRow(package: pkg, dashboardViewModel: dashboardViewModel)
                }
                .scrollContentBackground(.hidden)
            }
        }
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

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("Search package…"), text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: CardCornerRadius.small))
    }
}
