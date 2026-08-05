import SwiftUI

struct HomeView: View {
    let dashboardViewModel: DashboardViewModel
    let navigation: DashboardNavigation

    @ScaledMetric(relativeTo: .caption) private var countColumnWidth: CGFloat = 44

    private func formattedCount(_ count: Int) -> String {
        switch count {
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(count) / 1_000)
        default: "\(count)"
        }
    }

    private var trending: [TrendingPackage] { dashboardViewModel.trending }
    private var recommended: [TrendingPackage] { dashboardViewModel.recommended }

    var body: some View {
        Group {
            if dashboardViewModel.isLoading {
                // Without this, opening the Dashboard right after launch showed the stat
                // cards at 0 (Trending/Recommended hidden by their own isEmpty checks) —
                // reading as "nothing installed" on a machine with plenty, for however long
                // waitUntilConfigured()/load() take to resolve.
                LoadingView()
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
                // Orange only when there's actually something to attend to — at 0 it's a
                // plain fact like the other three cards, not a "needs attention" cue.
                tint: dashboardViewModel.outdatedInstalledCount > 0 ? .outdatedBadge : .accentColor
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

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L("Trending in Homebrew"))

            VStack(spacing: 0) {
                ForEach(Array(trending.prefix(6))) { package in
                    PackageBrowseRow(
                        name: package.name,
                        isCask: package.isCask,
                        accessibilityLabel: "\(package.name), \(formattedCount(package.installCount)) \(L("installs"))",
                        trailing: AnyView(
                            Text(formattedCount(package.installCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: countColumnWidth, alignment: .trailing)
                        )
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    if package.id != trending.prefix(6).last?.id {
                        Divider()
                    }
                }
            }
            .padding(.vertical, 4)
            .cardBackground()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recommended

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L("Recommended for you"))

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
                SectionHeader(title: L("Install Packs"))
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
                PackageInfoButton(name: package.name, isCask: package.isCask)
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
                        dashboardViewModel.installSingle(name: package.name, isCask: package.isCask)
                    }
                    .disabled(dashboardViewModel.isInstalling)
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
        .cardBackground()
        .accessibilityElement(children: .contain)
        .task { desc = await dashboardViewModel.description(for: package) }
    }
}
