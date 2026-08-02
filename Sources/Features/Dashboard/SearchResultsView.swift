import SwiftUI

struct SearchResultsView: View {
    let dashboardViewModel: DashboardViewModel
    let onClearSearch: () -> Void

    var body: some View {
        Group {
            if dashboardViewModel.isSearching && dashboardViewModel.searchResults.isEmpty {
                LoadingView(label: L("Searching…"), fillHeight: true)
            } else if dashboardViewModel.searchResults.isEmpty {
                ContentUnavailableView {
                    Label(L("No results for \"\(dashboardViewModel.searchQuery)\""), systemImage: "magnifyingglass")
                } actions: {
                    Button(L("Clear Search")) { onClearSearch() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                List(dashboardViewModel.searchResults) { result in
                    SearchResultRow(result: result, dashboardViewModel: dashboardViewModel)
                }
                .scrollContentBackground(.hidden)
            }
        }
        // The query itself is information, so it goes in the native subtitle slot
        // instead of the toolbar; the spinner and Clear Search button are the real
        // actions/status, so those stay in the toolbar.
        .navigationSubtitle(dashboardViewModel.searchQuery.isEmpty ? "" : "\"\(dashboardViewModel.searchQuery)\"")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    if dashboardViewModel.isSearching {
                        ProgressView().controlSize(.small)
                    }
                    // An explicit way back to Home — the sidebar search field is easy to
                    // miss as the only "exit" once results fill the whole detail pane.
                    Button(L("Clear Search")) { onClearSearch() }
                }
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
        if disabled { parts.append(L("disabled")) }
        else if deprecated { parts.append(L("deprecated")) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        PackageBrowseRow(
            name: result.name,
            isCask: result.isCask,
            dashboardViewModel: dashboardViewModel,
            accessibilityLabel: accessibilityLabel,
            leading: (disabled || deprecated) ? AnyView(
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(disabled ? Color.disabledBadge : Color.deprecatedBadge)
            ) : nil,
            trailing: disabled ? AnyView(StatusBadge(text: L("Disabled"), color: .disabledBadge))
                : deprecated ? AnyView(StatusBadge(text: L("Deprecated"), color: .deprecatedBadge))
                : nil
        )
        .padding(.vertical, 4)
        .task {
            (deprecated, disabled) = await dashboardViewModel.deprecationStatus(for: result.name, isCask: result.isCask)
        }
    }
}
