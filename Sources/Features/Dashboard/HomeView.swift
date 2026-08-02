import SwiftUI

struct HomeView: View {
    let dashboardViewModel: DashboardViewModel
    let navigation: DashboardNavigation

    /// Top trending formulae + casks merged and ranked by install count.
    private var trending: [TrendingPackage] {
        (dashboardViewModel.trendingFormulae + dashboardViewModel.trendingCasks)
            .sorted { $0.installCount > $1.installCount }
    }

    private var recommended: [TrendingPackage] {
        Array(trending.filter { !dashboardViewModel.isInstalled($0.name) }.prefix(3))
    }

    var body: some View {
        if dashboardViewModel.isLoading {
            // Without this, opening the Dashboard right after launch showed the stat
            // cards at 0 (Trending/Recommended hidden by their own isEmpty checks) —
            // reading as "nothing installed" on a machine with plenty, for however long
            // waitUntilConfigured()/load() take to resolve.
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statCards

                    if !trending.isEmpty {
                        trendingSection
                    }

                    if !recommended.isEmpty {
                        recommendedSection
                    }

                    installPacksSection
                }
                .padding()
            }
        }
    }

    // MARK: - Stat cards

    private var statCards: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            // Only Outdated carries real semantic meaning (same orange used for every
            // "needs attention" state elsewhere — MenuBarStatus.updates, StatusBadge).
            // The other three are plain facts, not severities, so they share the app's
            // one accent tint instead of each claiming its own arbitrary hue — four
            // unrelated colors in one row read as decoration, not information.
            StatCard(
                title: L("Installed packages"),
                value: "\(dashboardViewModel.installedCount)",
                systemImage: "square.grid.2x2.fill",
                tint: .accentColor
            ) { navigation.selectedSection = .installed }

            StatCard(
                title: L("Outdated"),
                value: "\(dashboardViewModel.outdatedInstalledCount)",
                systemImage: "arrow.up.circle.fill",
                tint: .outdatedBadge
            ) { navigation.selectedSection = .outdatedPackages }

            StatCard(
                title: L("Active ecosystems"),
                value: "\(dashboardViewModel.activeEcosystemsCount)",
                systemImage: "cube.box.fill",
                tint: .accentColor,
                // With nothing installed yet there's nothing to show on the overview
                // screen either — disabled instead of navigating to an empty list.
                isEnabled: !dashboardViewModel.ecosystems.isEmpty
            ) { navigation.selectedSection = .ecosystemsOverview }

            StatCard(
                title: L("Install packs"),
                value: "\(dashboardViewModel.installPacks.count)",
                systemImage: "shippingbox.fill",
                tint: .accentColor
            ) { navigation.selectedSection = .installPacks }
        }
    }

    // MARK: - Trending

    // This screen's section headers (here, Recommended, Install Packs) are
    // `.headline` — one screen's worth of full-width page sections in a spacious
    // window, not the popover's stacked, space-constrained group labels (see
    // MenuBarView.groupLabel). Same role, deliberately different scale for a
    // deliberately different container.
    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Trending in Homebrew"))
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(trending.prefix(6))) { package in
                    TrendingRow(package: package, dashboardViewModel: dashboardViewModel)
                    if package.id != trending.prefix(6).last?.id {
                        Divider()
                    }
                }
            }
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: CardCornerRadius.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recommended

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Recommended for you"))
                .font(.headline)

            HStack(alignment: .top, spacing: 12) {
                ForEach(recommended) { package in
                    RecommendedCard(package: package, dashboardViewModel: dashboardViewModel)
                }
            }
        }
    }

    // MARK: - Install Packs

    private var installPacksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Install Packs"))
                    .font(.headline)
                Spacer()
                Button(L("View all")) { navigation.selectedSection = .installPacks }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }

            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(dashboardViewModel.installPacks.prefix(3))) { pack in
                    InstallPackCard(pack: pack, dashboardViewModel: dashboardViewModel)
                }
            }
        }
    }
}

// MARK: - TrendingRow

private struct TrendingRow: View {
    let package: TrendingPackage
    let dashboardViewModel: DashboardViewModel

    @ScaledMetric(relativeTo: .caption) private var countColumnWidth: CGFloat = 44
    // Narrower than before now that this column holds a fixed 24pt icon instead of a
    // variable-width text pill.
    @ScaledMetric(relativeTo: .caption) private var statusColumnWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: package.isCask ? "app.badge" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(verbatim: package.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 12)

                Text(formattedCount(package.installCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: countColumnWidth, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(package.name), \(formattedCount(package.installCount)) \(L("installs"))")

            Button {
                dashboardViewModel.selectPackage(name: package.name, isCask: package.isCask)
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
            .help(L("Package info"))
            .accessibilityLabel(L("Package info for \(package.name)"))

            // Fixed-width status column — a status pill, a spinner, and an "Install"
            // button are all very different sizes; without a shared frame the row
            // visibly jumps depending on which one is showing.
            PackageStatusIndicator(name: package.name, isCask: package.isCask, dashboardViewModel: dashboardViewModel)
                .frame(width: statusColumnWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func formattedCount(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }
}

// MARK: - RecommendedCard

private struct RecommendedCard: View {
    let package: TrendingPackage
    let dashboardViewModel: DashboardViewModel
    @State private var desc: String?

    private var failed: Bool { dashboardViewModel.failedInstallNames.contains(package.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: package.isCask ? "app.badge" : "terminal")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Spacer()
                Button {
                    dashboardViewModel.selectPackage(name: package.name, isCask: package.isCask)
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
                .help(L("Package info"))
                .accessibilityLabel(L("Package info for \(package.name)"))
            }
            Text(verbatim: package.name)
                .font(.headline)
                .lineLimit(1)
            Text(desc ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if dashboardViewModel.installingNames.contains(package.name) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L("Installing \(package.name)"))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    if failed {
                        // Card's too narrow for the real brew error inline — it's a
                        // tooltip instead of a hardcoded "check the name" guess.
                        Label(L("Install failed"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .help(dashboardViewModel.installErrors[package.name] ?? "")
                    }
                    Button(failed ? L("Try Again") : L("Install")) {
                        Task { await dashboardViewModel.install(name: package.name, isCask: package.isCask) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(failed ? .red : .accentColor)
                    .accessibilityLabel(failed ? L("Retry installing \(package.name)") : L("Install \(package.name)"))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 130, alignment: .top)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: CardCornerRadius.medium))
        .accessibilityElement(children: .contain)
        .task { desc = await dashboardViewModel.description(for: package) }
    }
}
