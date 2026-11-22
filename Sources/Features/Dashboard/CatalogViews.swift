import BrewCore
import SwiftUI

// MARK: - Apps / Command Line

/// Every app (casks that install one) or every formula in the catalog, most installed first —
/// the App Store's "Apps" and "Developer Tools" pages, for Homebrew.
struct CatalogBrowseView: View {
    enum Kind {
        case apps, commandLine
    }

    enum Order: String, CaseIterable, Identifiable {
        case popular, name

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .popular: L("Most Installed")
            case .name: L("Name")
            }
        }
    }

    let kind: Kind
    let dashboardViewModel: DashboardViewModel

    @State private var order: Order = .popular

    private var store: BrewStore {
        dashboardViewModel.store
    }

    private var rankingKey: DashboardViewModel.RankingKey {
        dashboardViewModel.rankingKey(apps: kind == .apps, byPopularity: order == .popular)
    }

    /// Sorted off the main actor and kept by the view model (see `DashboardViewModel.rank`).
    private var packages: [CatalogPackage]? {
        dashboardViewModel.ranking(for: rankingKey)
    }

    var body: some View {
        Group {
            if let packages {
                // One kind per list, so the name alone identifies a row.
                List(packages, id: \.name) { package in
                    StorePackageRow(package: package)
                }
                .scrollContentBackground(.hidden)
                // A new list per order, not the same one re-sorted: the same thousands of rows in
                // another order reach NSTableView as one move per row, which hung the app.
                .id(rankingKey)
            } else if store.catalog == nil, let error = store.catalogError {
                RetryableErrorState(title: L("Couldn't load the package catalog"), message: error) {
                    Task { await store.refreshCatalog() }
                }
            } else {
                LoadingView(label: L("Loading the package catalog…"), fillHeight: true)
            }
        }
        .task(id: rankingKey) { await dashboardViewModel.rank(rankingKey) }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(L("Sort by"), selection: $order) {
                    ForEach(Order.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help(L("Sort by"))
            }
        }
    }

    private var subtitle: String {
        guard let count = packages?.count else { return "" }
        return switch kind {
        case .apps: L("\(count) apps")
        case .commandLine: L("\(count) tools")
        }
    }
}

// MARK: - Collections

/// The collection grid: a symbol and a name per collection, three columns, hairlines between rows.
struct CollectionGrid: View {
    let packs: [InstallPack]
    let columns: [GridItem]
    let onSelect: (InstallPack) -> Void

    var body: some View {
        // A hairline under every row but the last, as in the App Store.
        let lastRowStart = (packs.count - 1) / columns.count * columns.count
        LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
            ForEach(Array(packs.enumerated()), id: \.element.id) { index, pack in
                Button { onSelect(pack) } label: {
                    CollectionTile(pack: pack, showsDivider: index < lastRowStart)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One collection: what it's for, its packages, and a way to install all of them at once.
struct CollectionDetailView: View {
    let pack: InstallPack
    let dashboardViewModel: DashboardViewModel

    private var packages: [CatalogPackage] {
        pack.formulae.map { catalogEntry($0, isCask: false, in: dashboardViewModel.store) }
            + pack.casks.map { catalogEntry($0, isCask: true, in: dashboardViewModel.store) }
    }

    var body: some View {
        List {
            Section {
                ForEach(packages) { StorePackageRow(package: $0) }
            } header: {
                header
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(pack.localizedTitle)
        .navigationSubtitle(pack.packageCount == 1 ? L("1 package") : L("\(pack.packageCount) packages"))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: pack.systemImage)
                .font(.system(size: 30))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(CollectionTile.tint(for: pack.id).gradient, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(pack.localizedTitle)
                    .font(.title.bold())
                    .foregroundStyle(.primary)
                Text(pack.localizedSubtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Install All")) { dashboardViewModel.installPack(pack) }
                .buttonStyle(.roomyBorderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(dashboardViewModel.isInstalling || allInstalled)
                .help(dashboardViewModel.isInstalling ? L("Another install is in progress") : "")
                .accessibilityLabel(L("Install \(pack.localizedTitle) pack"))
        }
        .textCase(nil)
        .padding(.vertical, 12)
    }

    private var allInstalled: Bool {
        (pack.formulae + pack.casks).allSatisfy(dashboardViewModel.isInstalled)
    }
}
