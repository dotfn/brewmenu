import AppKit
import SwiftUI

/// Disambiguates identical raw ids across the several `ForEach` loops sharing one
/// `LazyVStack` — e.g. a formula and a `brew services` entry can both be named
/// "cloudflared", so `OutdatedPackage.id`/`ServiceEntry.id` (both just the name)
/// collide once both rows land in the same lazy container's id space. A plain
/// `VStack` tolerated this silently; `LazyVStack`'s id-keyed view list doesn't
/// (confirmed via its runtime "used by multiple child views" warning).
private struct ScopedRow<Value>: Identifiable {
    let id: String
    let value: Value
}

struct MenuBarView: View {
    let viewModel: MenuBarViewModel
    let dashboardNav: DashboardNavigation
    @Environment(\.openWindow) private var openWindow
    @State private var searchText: String = ""

    private var filteredPackages: [OutdatedPackage] {
        guard !searchText.isEmpty else { return viewModel.outdatedPackages }
        return viewModel.outdatedPackages.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// The popover's inline group label ("Insights" / "Services" / "Outdated
    /// Packages" / "brew doctor") — `SectionHeader`'s `.compact` scale, deliberately
    /// smaller than the Dashboard's `.standard` section headers (see HomeView): this
    /// compact panel stacks up to four different content groups in one scroll, so its
    /// labels need to read as dividers between them, not as page titles competing with
    /// the rows below. Padding stays here, not in the shared component — it's this
    /// panel's own layout, not part of the title's visual style.
    private func groupLabel(_ title: String) -> some View {
        SectionHeader(title: title, scale: .compact)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if viewModel.needsRestart {
                RestartBanner()
                Divider()
            }
            content
                .frame(maxHeight: .infinity)
            Divider()
            footer
            Divider()
            actionRows
        }
        // Fixed height prevents AppKit "layoutSubtreeIfNeeded called during layout"
        // recursion: no window resize means no overlapping layout passes.
        .frame(width: 380, height: 520)
    }

    // MARK: - Action rows (replaces the old right-click NSMenu)

    private var actionRows: some View {
        VStack(spacing: 0) {
            ActionRow(title: L("Open Dashboard…"), systemImage: "square.grid.2x2", shortcutHint: "⌘D") {
                openDashboard(section: .home)
            }
            .keyboardShortcut("d", modifiers: .command)

            ActionRow(title: L("Settings…"), systemImage: "gearshape", shortcutHint: "⌘,") {
                openDashboard(section: .general)
            }
            .keyboardShortcut(",", modifiers: .command)

            ActionRow(title: L("Quit BrewMenu"), systemImage: "power", shortcutHint: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 4)
    }

    private func openDashboard(section: DashboardSection) {
        dashboardNav.selectedSection = section
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "dashboard")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.status.symbolName)
                .foregroundStyle(viewModel.status.tintColor)
                .font(.title3)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "BrewMenu")
                    .fontWeight(.semibold)
                statusLabel
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Group {
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { viewModel.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r", modifiers: .command)
                    .help(L("Check for updates"))
                }
            }
            .frame(width: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.status {
        case .initializing:
            Text(L("Initializing…"))
        case .ok:
            Text(L("Up to date"))
        case .updates(let count):
            Text(count == 1 ? L("1 update available") : L("\(count) updates available"))
        case .warning(let count):
            Text(count == 1 ? L("1 doctor warning") : L("\(count) doctor warnings"))
        case .error(let msg):
            Text(verbatim: msg).lineLimit(2)
        }
    }

    // MARK: - Content

    // Extracted so the @ViewBuilder below only ever evaluates a single boolean per
    // branch — inlining this chain of &&s directly in the `if` conditions is what
    // used to make the type-checker choke on 4+ top-level branches, not the branch
    // count itself.
    private var hasNothingToShow: Bool {
        viewModel.doctorWarnings.isEmpty
            && viewModel.outdatedPackages.isEmpty
            && viewModel.insights.isEmpty
            && viewModel.visibleServices.isEmpty
            && !viewModel.isUpgrading
    }

    @ViewBuilder
    private var content: some View {
        if case .initializing = viewModel.status {
            VStack {
                Spacer()
                ProgressView(L("Checking Homebrew…"))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if case .error(let message) = viewModel.status, hasNothingToShow {
            errorState(message)
        } else if hasNothingToShow {
            VStack {
                Spacer()
                Label { Text(L("Up to date")) } icon: { Image(systemName: "checkmark.circle") }
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            mainContent
        }
    }

    // Surfaced separately from the header's `.caption` status text: when there's
    // nothing else in the popover, an error hiding in a one-line secondary label
    // read as "Up to date" at a glance (the checkmark empty-state used to render
    // here regardless of `status`) — this makes the failure the actual focal point.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            Text(verbatim: message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button(L("Retry")) { viewModel.refresh() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // Separates upgrade progress from the package list to keep `content` at 3 branches.
    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isUpgrading {
            upgradeProgressView
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Kept outside the ScrollView so it reads as a persistent indicator
                // rather than being scrolled away with the list content.
                if !viewModel.insights.isEmpty {
                    insightsSection
                    Divider()
                }
                if !viewModel.outdatedPackages.isEmpty {
                    SearchField(text: $searchText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    Divider()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !viewModel.doctorWarnings.isEmpty {
                            groupLabel("brew doctor")

                            let warnings = viewModel.doctorWarnings.map { ScopedRow(id: "doctor-\($0.id)", value: $0) }
                            ForEach(warnings) { row in
                                DoctorWarningRow(warning: row.value)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                if row.id != warnings.last?.id {
                                    Divider().padding(.leading, 12)
                                }
                            }

                            if !viewModel.outdatedPackages.isEmpty || !viewModel.visibleServices.isEmpty {
                                Divider().padding(.vertical, 4)
                            }
                        }

                        packagesAndServicesContent
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupLabel(L("Insights"))

            ForEach(viewModel.insights) { insight in
                InsightRow(insight: insight, viewModel: viewModel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                if insight.id != viewModel.insights.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var packagesAndServicesContent: some View {
        let services = viewModel.visibleServices.map { ScopedRow(id: "service-\($0.id)", value: $0) }
        let packages = filteredPackages.map { ScopedRow(id: "package-\($0.id)", value: $0) }

        if !services.isEmpty {
            groupLabel(L("Services"))

            ForEach(services) { row in
                let entry = row.value
                ServiceRow(
                    entry: entry,
                    isToggling: viewModel.togglingServices.contains(entry.name),
                    onStart: { viewModel.startService(entry.name) },
                    onStop: { viewModel.stopService(entry.name) }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                if row.id != services.last?.id {
                    Divider().padding(.leading, 12)
                }
            }

            Divider().padding(.vertical, 4)
        }

        if !viewModel.outdatedPackages.isEmpty {
            groupLabel(L("Outdated Packages"))
        }

        if packages.isEmpty && !searchText.isEmpty {
            Text(L("No results for \"\(searchText)\""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else {
            ForEach(packages) { row in
                let pkg = row.value
                PackageRow(
                    package: pkg,
                    isUpgrading: viewModel.upgradingPackages.contains(pkg.name),
                    onUpgrade: { viewModel.upgradePackage(pkg.name) }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                if row.id != packages.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private var upgradeProgressView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(viewModel.upgradeLog.enumerated()), id: \.offset) { index, line in
                        Text(verbatim: line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    if viewModel.upgradeLog.isEmpty {
                        Text(L("Starting upgrade…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: viewModel.upgradeLog.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let date = viewModel.lastChecked {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if viewModel.isUpgrading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Updating…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(L("Cancel")) { viewModel.cancelUpgrade() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                Button(L("Upgrade All")) { viewModel.upgradeAll() }
                    .disabled(viewModel.isRefreshing || viewModel.outdatedPackages.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - ActionRow

/// A menu-style row for the panel's bottom section (Open Dashboard / Settings /
/// Quit) — styled to read like a native menu item without being a real NSMenuItem,
/// so it lives in the same unified panel instead of a separate right-click menu.
private struct ActionRow: View {
    let title: String
    let systemImage: String
    let shortcutHint: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                Text(title)
                Spacer()
                Text(verbatim: shortcutHint)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.primary.opacity(0.08) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

// MARK: - PackageRow

struct PackageRow: View {
    let package: OutdatedPackage
    let isUpgrading: Bool
    let onUpgrade: () -> Void

    private var fromVersion: String { package.installedVersions.first ?? "?" }

    var body: some View {
        HStack(spacing: 6) {
            // Grouped as one VoiceOver stop (name + current→available version) — this
            // is the app's primary popover surface, so ungrouped rows here meant every
            // name/version/button was a separate, disconnected stop.
            HStack(spacing: 6) {
                Text(verbatim: package.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 6)

                if !isUpgrading {
                    HStack(spacing: 3) {
                        Text(verbatim: fromVersion)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 64, alignment: .trailing)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        Text(verbatim: package.currentVersion)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 64, alignment: .leading)
                    }
                    .font(.caption)
                    // Truncated versions (long hashes/dates) stay reachable via tooltip.
                    .help("\(fromVersion) → \(package.currentVersion)")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isUpgrading
                ? L("\(package.name), updating")
                : L("\(package.name), update available from \(fromVersion) to \(package.currentVersion)")
            )

            if isUpgrading {
                ProgressView()
                    .controlSize(.small)
            } else {
                // Always in the view tree (not hover-gated) so VoiceOver and
                // keyboard/Tab navigation can reach it — this is the only way
                // to upgrade a single package.
                Button(L("Update")) { onUpgrade() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel(L("Update \(package.name)"))
            }
        }
    }
}

// MARK: - ServiceRow

struct ServiceRow: View {
    let entry: ServiceEntry
    let isToggling: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.status.tintColor)
                    .frame(width: 8, height: 8)

                Text(verbatim: entry.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(entry.name), \(entry.status.accessibilityDescription)")

            if isToggling {
                ProgressView().controlSize(.small).frame(width: 36)
                    .accessibilityLabel(L("Updating \(entry.name)"))
            } else {
                switch entry.status {
                case .started:
                    Button(L("Stop"), action: onStop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                        .accessibilityLabel(L("Stop \(entry.name)"))
                case .stopped, .error, .inactive:
                    Button(L("Start"), action: onStart)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.green)
                        .accessibilityLabel(L("Start \(entry.name)"))
                case .unknown:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - InsightRow

struct InsightRow: View {
    let insight: Insight
    /// Only needed to wire up the "Clean Up" / "Remove" actions on the
    /// cleanup-pending and unused-dependencies insights — every other insight is
    /// purely informational and ignores this.
    var viewModel: MenuBarViewModel? = nil

    @State private var showingCleanupConfirmation = false
    @State private var showingAutoremoveConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: insight.severity.symbolName)
                .foregroundStyle(insight.severity.tintColor)
                .font(.caption)
                .frame(width: 14, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: insight.title)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(verbatim: insight.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let viewModel {
                if insight.id == "cleanup-pending" {
                    cleanupAction(viewModel)
                } else if insight.id == "unused-dependencies" {
                    autoremoveAction(viewModel)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(insight.title). \(insight.detail)")
    }

    @ViewBuilder
    private func cleanupAction(_ viewModel: MenuBarViewModel) -> some View {
        if viewModel.isCleaningUp {
            ProgressView().controlSize(.small)
                .accessibilityLabel(L("Cleaning up"))
        } else {
            Button(L("Clean Up")) { showingCleanupConfirmation = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isUpgrading || viewModel.isRefreshing)
                .confirmationDialog(
                    L("Run brew cleanup?"),
                    isPresented: $showingCleanupConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(L("Clean Up"), role: .destructive) { viewModel.cleanUp() }
                    Button(L("Cancel"), role: .cancel) {}
                } message: {
                    Text(L("Removes old package versions and cached downloads. This can't be undone."))
                }
        }
    }

    @ViewBuilder
    private func autoremoveAction(_ viewModel: MenuBarViewModel) -> some View {
        if viewModel.isRemovingUnusedDependencies {
            ProgressView().controlSize(.small)
                .accessibilityLabel(L("Removing"))
        } else {
            Button(L("Remove")) { showingAutoremoveConfirmation = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.red)
                .disabled(viewModel.isUpgrading || viewModel.isRefreshing || viewModel.isCleaningUp)
                .confirmationDialog(
                    viewModel.autoremovableFormulae.count == 1
                        ? L("Uninstall 1 unused package?")
                        : L("Uninstall \(viewModel.autoremovableFormulae.count) unused packages?"),
                    isPresented: $showingAutoremoveConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(L("Uninstall"), role: .destructive) { viewModel.removeUnusedDependencies() }
                    Button(L("Cancel"), role: .cancel) {}
                } message: {
                    // Unlike Clean Up (deletes cached files), this actually uninstalls
                    // whole packages — spelling out exactly which ones, not just "some
                    // packages", so the confirmation means something.
                    Text(L("This will uninstall: \(viewModel.autoremovableFormulae.sorted().joined(separator: ", ")). You can reinstall any of them later if needed."))
                }
        }
    }
}

// MARK: - DoctorWarningRow

struct DoctorWarningRow: View {
    let warning: DoctorWarning

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: warning.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(warning.severity == .error ? .red : .orange)
                .font(.caption)
                .frame(width: 14, alignment: .center)
                .padding(.top, 1)

            Text(verbatim: warning.message)
                .font(.caption)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ServiceEntry.Status presentation (view layer)

private extension ServiceEntry.Status {
    var tintColor: Color {
        switch self {
        case .started: .green
        case .stopped: .secondary
        case .error: .red
        case .inactive, .unknown: .secondary
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .started: L("running")
        case .stopped: L("stopped")
        case .error: L("error")
        case .inactive, .unknown: L("inactive")
        }
    }
}

// MARK: - Insight.Severity presentation (view layer)

private extension Insight.Severity {
    var symbolName: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

// MARK: - MenuBarStatus presentation (view layer)

private extension MenuBarStatus {
    var symbolName: String {
        switch self {
        case .initializing: "hourglass"
        case .ok: "checkmark.circle.fill"
        case .updates: "arrow.down.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .initializing: .secondary
        case .ok: .green
        // Matches the "updates available" color everywhere else in the app (Home's
        // StatCard, the Outdated StatusBadge, Insight.Severity.warning) — this used
        // to be yellow, the only place that state wasn't orange.
        case .updates: .orange
        case .warning: .orange
        case .error: .red
        }
    }
}
