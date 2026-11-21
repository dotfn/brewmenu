import BrewCore
import SwiftUI

struct HomeView: View {
    let dashboardViewModel: DashboardViewModel
    let navigation: DashboardNavigation

    var body: some View {
        Group {
            if dashboardViewModel.isLoading {
                // Without this, opening the Dashboard right after launch showed the stat
                // cards at 0 (the popular sections hidden by their own isEmpty checks) —
                // reading as "nothing installed" on a machine with plenty, for however long
                // waitUntilConfigured()/load() take to resolve.
                LoadingView()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        collectionsSection

                        if let error = dashboardViewModel.trendingError, dashboardViewModel.trending.isEmpty {
                            trendingFailure(error)
                        } else {
                            popularSection(
                                title: L("Popular Apps"),
                                packages: popularApps,
                                seeAll: { navigation.selectedSection = .apps }
                            )
                            popularSection(
                                title: L("Popular Command-Line Tools"),
                                packages: popularTools,
                                seeAll: { navigation.selectedSection = .commandLine }
                            )
                        }
                    }
                    .padding(24)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // One persistent Button, not an if/else swap between a raw ProgressView
                // and a Button at the ToolbarItem's root — swapping the root view type
                // confused macOS's automatic circular hover chrome for icon-only toolbar
                // buttons (looked right on hover, wrong at rest). Only the label content
                // swaps, so the system keeps applying the same chrome throughout.
                Button {
                    Task { await dashboardViewModel.refresh() }
                } label: {
                    if dashboardViewModel.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(dashboardViewModel.isRefreshing)
                .help(L("Refresh — re-check what's installed and clear any failed install/uninstall attempts"))
                .accessibilityLabel(L("Refresh"))
            }
        }
    }

    /// The most installed apps and tools of the last 30 days (Homebrew's analytics), as catalog
    /// entries — with only a name and a monogram until the catalog has loaded.
    private var popularApps: [CatalogPackage] {
        popular(dashboardViewModel.trendingCasks, isCask: true).filter { $0.isApp || $0.appPath == nil }
    }

    private var popularTools: [CatalogPackage] {
        popular(dashboardViewModel.trendingFormulae, isCask: false)
    }

    private func popular(_ trending: [TrendingPackage], isCask: Bool) -> [CatalogPackage] {
        Array(trending.prefix(8)).map { catalogEntry($0.name, isCask: isCask, in: dashboardViewModel.store) }
    }

    // MARK: - Popular

    private func trendingFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StoreSectionHeader(title: L("Popular Apps"))
            HStack {
                InlineError(message: message)
                Button(L("Retry")) { Task { await dashboardViewModel.loadTrending() } }
                    .buttonStyle(.roomyBordered)
                    .controlSize(.small)
            }
        }
    }

    private let popularColumns = [GridItem(.flexible(), spacing: 32), GridItem(.flexible(), spacing: 32)]

    /// Two columns of rows with a hairline under each, like the App Store's Editors' Choice.
    @ViewBuilder
    private func popularSection(title: String, packages: [CatalogPackage], seeAll: @escaping () -> Void) -> some View {
        if !packages.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                StoreSectionHeader(title: title, seeAll: seeAll)
                LazyVGrid(columns: popularColumns, alignment: .leading, spacing: 0) {
                    ForEach(packages) { package in
                        VStack(spacing: 0) {
                            StorePackageRow(package: package, iconSize: 48)
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Collections

    private let collectionColumns = Array(repeating: GridItem(.flexible(), spacing: 32), count: 3)

    /// Every collection, first thing on the page — the App Store's Categories grid. It took the
    /// place of the installed/outdated counts, which the sidebar already shows.
    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Collections"))
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            CollectionGrid(
                packs: dashboardViewModel.installPacks,
                columns: collectionColumns,
                onSelect: navigation.openCollection
            )
        }
    }
}
