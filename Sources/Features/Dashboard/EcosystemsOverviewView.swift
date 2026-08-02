import SwiftUI

/// Every ecosystem (official + third-party) the user has at least one package
/// installed from, with its package count — what Home's "Active ecosystems" stat
/// actually counts. Tapping a row drills into that ecosystem's own package list.
struct EcosystemsOverviewView: View {
    let dashboardViewModel: DashboardViewModel
    let navigation: DashboardNavigation

    var body: some View {
        List {
            ForEach(dashboardViewModel.ecosystems) { tap in
                EcosystemOverviewRow(tap: tap, dashboardViewModel: dashboardViewModel, navigation: navigation)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationSubtitle(dashboardViewModel.ecosystems.count == 1 ? L("1 ecosystem") : L("\(dashboardViewModel.ecosystems.count) ecosystems"))
    }
}

private struct EcosystemOverviewRow: View {
    let tap: Tap
    let dashboardViewModel: DashboardViewModel
    let navigation: DashboardNavigation

    private var packages: [InstalledPackage] {
        dashboardViewModel.packages(in: tap).sorted { $0.name < $1.name }
    }

    var body: some View {
        let packages = packages
        // The GitHub link now lives in the ecosystem detail screen's own toolbar
        // (reached one tap away via the chevron below) — a second link straight from
        // this row was redundant, not an extra convenience.
        Button {
            navigation.selectedSection = .ecosystem(tap.name)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "cube.box")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tap.displayName)
                        officialBadge
                    }
                    if !packages.isEmpty {
                        Text(packages.map(\.name).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(packages.count == 1 ? L("1 package") : L("\(packages.count) packages"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("\(tap.displayName), \(packages.count) packages"))
        .accessibilityHint(L("Opens this section"))
    }

    private var officialBadge: some View {
        Text(tap.isOfficial ? L("Official") : L("Third-Party"))
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.secondary.opacity(0.2), in: Capsule())
    }
}
