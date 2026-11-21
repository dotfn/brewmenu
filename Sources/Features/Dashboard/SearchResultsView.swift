import BrewCore
import SwiftUI

struct SearchResultsView: View {
    let dashboardViewModel: DashboardViewModel
    let onClearSearch: () -> Void

    var body: some View {
        Group {
            if dashboardViewModel.isSearching, dashboardViewModel.searchResults.isEmpty {
                LoadingView(label: L("Searching…"), fillHeight: true)
            } else if dashboardViewModel.searchResults.isEmpty, let error = dashboardViewModel.searchError {
                RetryableErrorState(title: L("Search failed"), message: error) {
                    Task { await dashboardViewModel.commitSearch(dashboardViewModel.searchQuery) }
                }
            } else if dashboardViewModel.searchResults.isEmpty {
                ScrollableEmptyState {
                    ContentUnavailableView {
                        Label(L("No results for \"\(dashboardViewModel.searchQuery)\""), systemImage: "magnifyingglass")
                    } actions: {
                        Button(L("Clear Search")) { onClearSearch() }
                            .buttonStyle(.roomyBordered)
                            .controlSize(.small)
                    }
                }
            } else {
                List(dashboardViewModel.searchResults) { result in
                    // From the catalog it gets the full row (icon, description, pill); a
                    // third-party tap's package only has a name, so it keeps the plain one.
                    if let package = dashboardViewModel.store
                        .catalogPackage(named: result.name, isCask: result.isCask)
                    {
                        StorePackageRow(package: package)
                    } else {
                        SearchResultRow(result: result, dashboardViewModel: dashboardViewModel)
                    }
                }
                .scrollContentBackground(.hidden)
                // Old results stay until the new query lands, but dimmed — they no longer
                // match the query in the subtitle.
                .opacity(dashboardViewModel.isSearching ? 0.5 : 1)
            }
        }
        // The query itself is information, so it goes in the native subtitle slot
        // instead of the toolbar; the spinner and Clear Search button are the real
        // actions/status, so those stay in the toolbar.
        .navigationSubtitle(dashboardViewModel.searchQuery.isEmpty ? "" : "\"\(dashboardViewModel.searchQuery)\"")
        .toolbar {
            // Results are already up; this only says brew is still looking for more.
            if dashboardViewModel.isRefiningSearch {
                ToolbarItem(placement: .primaryAction) {
                    ProgressView()
                        .controlSize(.small)
                        .help(L("Looking for more matches…"))
                        .accessibilityLabel(L("Looking for more matches…"))
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // An explicit way back to Home — the sidebar search field is easy to
                // miss as the only "exit" once results fill the whole detail pane.
                Button(L("Clear Search")) { onClearSearch() }
            }
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    let dashboardViewModel: DashboardViewModel

    // `brew search` results carry only a name — deprecated/disabled status isn't
    // known until fetched lazily, same pattern as Recommended's description lookup.
    @State private var deprecated = false
    @State private var disabled = false

    private var accessibilityLabel: String {
        var parts = [result.name]
        if disabled { parts.append(L("disabled")) } else if deprecated { parts.append(L("deprecated")) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        PackageBrowseRow(
            name: result.name,
            isCask: result.isCask,
            accessibilityLabel: accessibilityLabel
        ) {
            // No leading warning triangle here — the trailing badge already says
            // "Disabled"/"Deprecated" in words, so the icon was just the same status
            // shown twice.
            if disabled {
                StatusBadge(text: L("Disabled"), color: .disabledBadge)
            } else if deprecated {
                StatusBadge(text: L("Deprecated"), color: .deprecatedBadge)
            }
        }
        .padding(.vertical, 4)
        .task {
            (deprecated, disabled) = await dashboardViewModel.deprecationStatus(for: result.name, isCask: result.isCask)
        }
    }
}
