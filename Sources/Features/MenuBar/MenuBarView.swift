import AppKit
import BrewCore
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
    /// Folded until opened: the services you keep installed rarely change, and the outdated
    /// packages below are what the popover is for. Remembered across openings of the popover and
    /// launches; `.brewMenu` keeps an isolated run from flipping the real app's choice.
    @AppStorage("menuBar.servicesCollapsed", store: .brewMenu) private var servicesCollapsed = true

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
    private func groupLabel(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            SectionHeader(title: title, scale: .compact)
            if let count { countPill(count) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: count.map { "\(title), \($0)" } ?? title))
        .accessibilityAddTraits(.isHeader)
    }

    /// How many rows a group holds — the same pill as the Dashboard sidebar's Updates count. The
    /// number is primary, not secondary: the gray on the pill's own fill measured ≈4.3:1.
    private func countPill(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    /// A `groupLabel` that folds its group away and says how many rows it holds, so a group that's
    /// always the same (the services you keep installed) can stay out of the way and still be
    /// counted at a glance. The whole label is the button.
    private func collapsibleGroupLabel(_ title: String, count: Int, isCollapsed: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                SectionHeader(title: title, scale: .compact)
                countPill(count)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.secondaryText)
                    .rotationEffect(.degrees(isCollapsed.wrappedValue ? -90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 2)
        // A Button is already one element; regrouping it (`.accessibilityElement(children:)`)
        // made a new element without the press action, so VoiceOver couldn't fold the group.
        .accessibilityLabel(Text(verbatim: "\(title), \(count)"))
        .accessibilityValue(isCollapsed.wrappedValue ? L("Collapsed") : L("Expanded"))
        .accessibilityAddTraits(.isHeader)
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
        // `MenuBarExtra(.window)` has no background of its own — without this,
        // its default material can pick up a strong tint from a custom System
        // Settings accent color instead of staying neutral (see `BrewTheme.swift`).
        .background(Color.brewWindowBackground)
    }

    // MARK: - Action rows (replaces the old right-click NSMenu)

    private var actionRows: some View {
        VStack(spacing: 0) {
            ActionRow(title: L("Open Dashboard…"), systemImage: "square.grid.2x2", shortcutHint: "⌘D") {
                openDashboard(section: .home)
            }
            .keyboardShortcut("d", modifiers: .command)

            ActionRow(title: L("Settings…"), systemImage: "gearshape", shortcutHint: "⌘,") {
                openDashboard(section: .settings)
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
                    .foregroundStyle(Color.secondaryText)
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
                    .accessibilityLabel(L("Check for updates"))
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
        case let .updates(count):
            Text(count == 1 ? L("1 upgrade available") : L("\(count) upgrades available"))
        case let .warning(count):
            Text(count == 1 ? L("1 doctor warning") : L("\(count) doctor warnings"))
        case let .error(msg):
            // Two lines is all the header has room for; the tooltip carries the rest.
            Text(verbatim: msg).lineLimit(2).help(msg)
        }
    }

    // MARK: - Content

    /// Extracted so the @ViewBuilder below only ever evaluates a single boolean per
    /// branch — inlining this chain of &&s directly in the `if` conditions is what
    /// used to make the type-checker choke on 4+ top-level branches, not the branch
    /// count itself.
    private var hasNothingToShow: Bool {
        viewModel.visibleDoctorWarnings.isEmpty
            && viewModel.outdatedPackages.isEmpty
            && viewModel.popoverInsights.isEmpty
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
        } else if case let .error(message) = viewModel.status, hasNothingToShow {
            errorState(message)
        } else if hasNothingToShow {
            VStack {
                Spacer()
                Label { Text(L("Up to date")) } icon: { Image(systemName: "checkmark.circle") }
                    .foregroundStyle(Color.secondaryText)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            mainContent
        }
    }

    /// Surfaced separately from the header's `.caption` status text: when there's
    /// nothing else in the popover, an error hiding in a one-line secondary label
    /// read as "Up to date" at a glance (the checkmark empty-state used to render
    /// here regardless of `status`) — this makes the failure the actual focal point.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.errorIcon)
            Text(verbatim: message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.secondaryText)
                .padding(.horizontal, 24)
            Button(L("Retry")) { viewModel.refresh() }
                .buttonStyle(.roomyBordered)
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Separates upgrade progress from the package list to keep `content` at 3 branches.
    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isUpgrading {
            upgradeProgressView
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Kept outside the ScrollView so it reads as a persistent indicator
                // rather than being scrolled away with the list content.
                if !viewModel.popoverInsights.isEmpty {
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
                        if !viewModel.visibleDoctorWarnings.isEmpty {
                            // Matches the Dashboard's own name for this section
                            // (`DashboardNavigation.swift`) — a non-technical user
                            // sees the same words in both places instead of the
                            // CLI subcommand name, and it was missing `L(...)`
                            // (never localized) until this fix.
                            groupLabel(L("Doctor Warnings"))

                            let warnings = viewModel.visibleDoctorWarnings
                                .map { ScopedRow(id: "doctor-\($0.id)", value: $0) }
                            ForEach(warnings) { row in
                                DoctorWarningRow(warning: row.value) { openDashboard(section: .doctorWarnings) }
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

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupLabel(L("Insights"))

            ForEach(viewModel.popoverInsights) { insight in
                InsightRow(insight: insight, viewModel: viewModel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                if insight.id != viewModel.popoverInsights.last?.id {
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
            collapsibleGroupLabel(L("Services"), count: services.count, isCollapsed: $servicesCollapsed)

            ForEach(servicesCollapsed ? [] : services) { row in
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
            groupLabel(L("Outdated Packages"), count: viewModel.outdatedPackages.count)
        }

        if packages.isEmpty, !searchText.isEmpty {
            Text(L("No results for \"\(searchText)\""))
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else {
            ForEach(packages) { row in
                let pkg = row.value
                PackageRow(
                    package: pkg,
                    isUpgrading: viewModel.upgradingPackages.contains(pkg.name),
                    isDisabled: viewModel.isRunningAnyUpgrade,
                    failure: viewModel.upgradeFailure(forPackage: pkg.name),
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
                            .foregroundStyle(Color.secondaryText)
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

    /// Ticks once a second so a run's elapsed time — and a run gone quiet — shows without waiting
    /// for brew to print something.
    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let activity = viewModel.upgradeActivity(at: context.date)
            if activity == .idle {
                idleFooter
            } else {
                UpgradeActivityBanner(
                    activity: activity,
                    onShowLog: showUpgradeLog,
                    onCancel: { viewModel.cancelUpgrade() },
                    onRetry: { viewModel.retryUpgrade() },
                    onDismiss: { viewModel.clearUpgradeFailure() }
                )
            }
        }
    }

    private var idleFooter: some View {
        HStack {
            if let date = viewModel.lastChecked {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(Color.secondaryText)
            }

            Spacer()

            Button(L("Upgrade All")) { viewModel.upgradeAll() }
                .disabled(viewModel.bulkUpgradeCount == 0)
                .disabled(viewModel.isRefreshing || viewModel.outdatedPackages.isEmpty)
                .buttonStyle(.roomyBorderedProminent)
                .controlSize(.small)
        }
        // The same height as the upgrade banner that takes its place, so the list doesn't jump.
        .frame(height: UpgradeActivityBanner.lineHeight)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The Dashboard's Updates page with the run's full log over it — the one place with every line.
    private func showUpgradeLog() {
        dashboardNav.showsUpgradeLog = true
        openDashboard(section: .outdatedPackages)
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
                    .foregroundStyle(Color.secondaryText)
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
    /// True while *any* upgrade runs — `onUpgrade` is a no-op then, so the button is
    /// shown disabled instead of looking clickable.
    var isDisabled = false
    /// Didn't go through the same review as homebrew/core/cask — shown as a small,
    /// neutral icon (not a color or a warning triangle): it's information to weigh
    /// before upgrading, not a problem. Defaults false so the popover's call site
    /// (MenuBarView, which has no tap data to answer this — see
    /// DashboardViewModel.isOfficialOrigin) doesn't need to change.
    var isThirdParty = false
    /// Why this package's own upgrade just failed (`MenuBarViewModel.upgradeFailure(forPackage:)`)
    /// — marked on the row itself, so it's clear which one went wrong, not only that one did.
    var failure: String?
    let onUpgrade: () -> Void

    private var fromVersion: String {
        package.installedVersions.first ?? "?"
    }

    @State private var isHovered = false
    @FocusState private var buttonHasFocus: Bool

    /// Version and Upgrade share one fixed-width slot on the right: the version until the pointer
    /// is on the row (or the button has keyboard focus), then the button in its place. Thirty-odd
    /// Upgrade buttons made a wall of the same call to action; hiding them during a run left an
    /// empty column with the versions stranded mid-row. Fixed width, so nothing moves either way.
    static let trailingSlotWidth: CGFloat = 112

    private var showsButton: Bool {
        (isHovered || buttonHasFocus) && !isDisabled && !isUpgrading
    }

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

                if isThirdParty {
                    Image(systemName: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(Color.secondaryText)
                        .help(L("From a third-party tap, not homebrew/core"))
                }

                if let failure, !isUpgrading {
                    // A shape as well as a color, like ServiceRow's error state.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.errorIcon)
                        .help(failure)
                }

                Spacer(minLength: 6)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                (isUpgrading
                    ? L("\(package.name), upgrading")
                    : L("\(package.name), upgrade available from \(fromVersion) to \(package.currentVersion)"))
                    + (failure.map { ". \(L("Upgrade failed")): \($0)" } ?? "")
                    + (isThirdParty ? ". \(L("From a third-party tap, not homebrew/core"))" : "")
            )

            ZStack(alignment: .trailing) {
                // Only the version an upgrade brings; the installed one is in the tooltip and in
                // what VoiceOver reads (the label above). Read there, so hidden from it here.
                Text(verbatim: package.currentVersion)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(fromVersion) → \(package.currentVersion)")
                    .opacity(showsButton || isUpgrading ? 0 : 1)
                    .accessibilityHidden(true)

                // Always in the view tree, shown or not, so VoiceOver and keyboard/Tab navigation
                // reach it — this is the only way to upgrade a single package. Neutral, not
                // prominent: Upgrade All is the one meant to lead (and white on the system blue
                // measures ≈3.65:1 on the dark popover).
                Button(L("Upgrade")) { onUpgrade() }
                    .buttonStyle(.roomyBordered)
                    .controlSize(.small)
                    .disabled(isDisabled || isUpgrading)
                    .opacity(showsButton ? 1 : 0)
                    .focused($buttonHasFocus)
                    .accessibilityHidden(isDisabled || isUpgrading)
                    .accessibilityLabel(L("Upgrade \(package.name)"))
                    .accessibilityIdentifier(AccessibilityID.packageUpgradeButton)

                if isUpgrading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: Self.trailingSlotWidth, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
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
                // A plain colored dot is identical for `.error` and `.stopped`/
                // `.inactive` to a colorblind or low-vision user with no screen
                // reader running (VoiceOver already gets the real state via
                // `accessibilityDescription` below) — `.error` gets a distinct
                // shape, not just a distinct color, so the failure is visible
                // without relying on color at all.
                if entry.status == .error {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(entry.status.tintColor)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(entry.status.tintColor)
                        .frame(width: 8, height: 8)
                }

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
                    Button(L("Stop"), role: .destructive, action: onStop)
                        .buttonStyle(.roomyBordered)
                        .controlSize(.small)
                        .accessibilityLabel(L("Stop \(entry.name)"))
                case .stopped, .error, .inactive:
                    Button(L("Start"), action: onStart)
                        .buttonStyle(.roomyBordered)
                        .controlSize(.small)
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
    var viewModel: MenuBarViewModel?

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
                    .foregroundStyle(Color.secondaryText)
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

    /// Where a maintenance run stands — step, time, or that brew has gone quiet — ticking every
    /// second. It replaced brew's raw latest line, which scrolled past too fast to read.
    private func runStatus(_ snapshot: @escaping (Date) -> CommandRunMonitor.Snapshot?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let run = snapshot(context.date) {
                CommandRunStatusLine(snapshot: run)
            }
        }
    }

    @ViewBuilder
    private func cleanupAction(_ viewModel: MenuBarViewModel) -> some View {
        if viewModel.isCleaningUp {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L("Cleaning up"))
                runStatus { viewModel.cleanupSnapshot(at: $0) }
                Button(L("Cancel")) { viewModel.cancelCleanUp() }
                    .buttonStyle(.roomyBordered)
                    .controlSize(.small)
            }
        } else {
            Button(L("Clean Up")) { showingCleanupConfirmation = true }
                .buttonStyle(.roomyBordered)
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
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L("Removing"))
                runStatus { viewModel.autoremoveSnapshot(at: $0) }
                Button(L("Cancel")) { viewModel.cancelRemoveUnusedDependencies() }
                    .buttonStyle(.roomyBordered)
                    .controlSize(.small)
            }
        } else {
            Button(L("Remove"), role: .destructive) { showingAutoremoveConfirmation = true }
                .buttonStyle(.roomyBordered)
                .controlSize(.small)
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
                    Text(
                        L(
                            "This will uninstall: \(viewModel.autoremovableFormulae.sorted().joined(separator: ", ")). You can reinstall any of them later if needed."
                        )
                    )
                }
        }
    }
}

// MARK: - DoctorWarningRow

/// The popover's line per finding: the title alone, opening the Dashboard's Doctor page where the
/// whole finding and its fix are. It used to show the full message cut at three lines, which kept
/// the problem's first lines and dropped the fix.
struct DoctorWarningRow: View {
    let warning: DoctorWarning
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: warning.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                    // `.outdatedIcon`, not plain `.orange` — same "needs attention" color
                    // as the popover header and Insights rows, not a third shade.
                    .foregroundStyle(warning.severity == .error ? Color.errorIcon : Color.outdatedIcon)
                    .font(.caption)
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                Text(verbatim: warning.title)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The only cue that the row opens something — `.tertiary` is under 3:1.
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(isHovered ? Color.primary : Color.secondaryText)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(warning.title)
        .accessibilityLabel(warning.title)
        // The icon that tells them apart is hidden.
        .accessibilityValue(warning.severity == .error ? L("Error") : L("Warning"))
        .accessibilityHint(L("Shows how to fix it in the Dashboard"))
    }
}

// MARK: - ServiceEntry.Status presentation (view layer)

private extension ServiceEntry.Status {
    var tintColor: Color {
        switch self {
        case .started: .successIcon
        case .stopped: .secondary
        case .error: .errorIcon
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
        // Same reasoning as `MenuBarStatus.tintColor` just above: `.outdatedIcon`,
        // not plain `.orange`, so an Insight row's warning triangle matches the
        // popover header's own "needs attention" color instead of being a third
        // shade of orange in the same window.
        case .warning: .outdatedIcon
        case .critical: .errorIcon
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
        case .ok: .successIcon
        // `.outdatedIcon`, not plain `.orange`: this is the popover header's own
        // icon (`arrow.down.circle.fill`), rendered right next to the menu bar's own
        // bitmap icon (`MenuBarIcon.swift`), which already uses `.outdatedIcon` for
        // this same state — two different oranges side by side otherwise, confirmed
        // against a real screenshot. A more vivid shade than the AA-for-text-fill
        // `.outdatedBadge` (user-requested — see `outdatedIcon`'s own doc comment).
        case .updates: .outdatedIcon
        case .warning: .outdatedIcon
        case .error: .errorIcon
        }
    }
}
