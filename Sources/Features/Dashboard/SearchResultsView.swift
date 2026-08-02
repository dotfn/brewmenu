import SwiftUI

struct SearchResultsView: View {
    let dashboardViewModel: DashboardViewModel
    let onClearSearch: () -> Void

    var body: some View {
        Group {
            if dashboardViewModel.isSearching && dashboardViewModel.searchResults.isEmpty {
                VStack {
                    Spacer()
                    ProgressView(L("Searching…"))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // Narrower than before now that this column holds a fixed 24pt icon instead of a
    // variable-width text pill.
    @ScaledMetric(relativeTo: .caption) private var statusColumnWidth: CGFloat = 28

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
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: result.isCask ? "app.badge" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                if disabled || deprecated {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(disabled ? Color.disabledBadge : Color.deprecatedBadge)
                }
                Text(verbatim: result.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if disabled {
                    StatusBadge(text: L("Disabled"), color: .disabledBadge)
                } else if deprecated {
                    StatusBadge(text: L("Deprecated"), color: .deprecatedBadge)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .task {
                (deprecated, disabled) = await dashboardViewModel.deprecationStatus(for: result.name, isCask: result.isCask)
            }

            Button {
                dashboardViewModel.selectPackage(name: result.name, isCask: result.isCask)
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
            .help(L("Package info"))
            .accessibilityLabel(L("Package info for \(result.name)"))

            // Fixed-width status column so the row doesn't jump in size between a
            // status pill, a spinner, and an "Install" button.
            PackageStatusIndicator(name: result.name, isCask: result.isCask, dashboardViewModel: dashboardViewModel)
                .frame(width: statusColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}
