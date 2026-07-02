import SwiftUI

struct MenuBarView: View {
    let viewModel: MenuBarViewModel
    let openSettings: () -> Void
    @State private var searchText: String = ""

    private var filteredPackages: [OutdatedPackage] {
        guard !searchText.isEmpty else { return viewModel.outdatedPackages }
        return viewModel.outdatedPackages.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if viewModel.needsRestart {
                restartBanner
                Divider()
            }
            content
                .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        // Fixed height prevents AppKit "layoutSubtreeIfNeeded called during layout"
        // recursion: no window resize means no overlapping layout passes.
        .frame(width: 380, height: 520)
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

    // MARK: - Restart Banner

    private var restartBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .foregroundStyle(.orange)
            Text(L("BrewMenu updated — restart to apply"))
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            Button(L("Restart")) {
                let url = Bundle.main.bundleURL
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Content

    // Kept at 3 branches — SwiftUI's @ViewBuilder layout breaks with 4+ top-level branches.
    @ViewBuilder
    private var content: some View {
        if case .initializing = viewModel.status {
            VStack {
                Spacer()
                ProgressView(L("Checking Homebrew…"))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if viewModel.doctorWarnings.isEmpty && viewModel.outdatedPackages.isEmpty && viewModel.insights.isEmpty && viewModel.visibleServices.isEmpty && !viewModel.isUpgrading {
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

    // Separates upgrade progress from the package list to keep `content` at 3 branches.
    @ViewBuilder
    private var mainContent: some View {
        if viewModel.isUpgrading {
            upgradeProgressView
        } else {
            VStack(spacing: 0) {
                if !viewModel.outdatedPackages.isEmpty {
                    searchBar
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !viewModel.insights.isEmpty {
                            Text(L("Insights"))
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                                .padding(.bottom, 2)

                            ForEach(viewModel.insights) { insight in
                                InsightRow(insight: insight)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                if insight.id != viewModel.insights.last?.id {
                                    Divider().padding(.leading, 12)
                                }
                            }

                            if !viewModel.doctorWarnings.isEmpty || !viewModel.outdatedPackages.isEmpty {
                                Divider().padding(.vertical, 4)
                            }
                        }

                        if !viewModel.doctorWarnings.isEmpty {
                            Text(verbatim: "brew doctor")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 6)
                                .padding(.bottom, 2)

                            ForEach(viewModel.doctorWarnings) { warning in
                                DoctorWarningRow(warning: warning)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                if warning.id != viewModel.doctorWarnings.last?.id {
                                    Divider().padding(.leading, 12)
                                }
                            }

                            if !viewModel.outdatedPackages.isEmpty {
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
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.callout)
            TextField(L("Search package…"), text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var packagesAndServicesContent: some View {
        if filteredPackages.isEmpty && !searchText.isEmpty {
            Text(L("No results for \"\(searchText)\""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        } else {
            ForEach(filteredPackages) { pkg in
                PackageRow(
                    package: pkg,
                    isUpgrading: viewModel.upgradingPackages.contains(pkg.name),
                    onUpgrade: { viewModel.upgradePackage(pkg.name) }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                if pkg.id != filteredPackages.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }

        if !viewModel.visibleServices.isEmpty {
            if !filteredPackages.isEmpty || !viewModel.doctorWarnings.isEmpty {
                Divider().padding(.vertical, 4)
            }

            Text(L("Services"))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(viewModel.visibleServices) { entry in
                ServiceRow(
                    entry: entry,
                    isToggling: viewModel.togglingServices.contains(entry.name),
                    onStart: { viewModel.startService(entry.name) },
                    onStop: { viewModel.stopService(entry.name) }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                if entry.id != viewModel.visibleServices.last?.id {
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
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(L("Settings"))

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

// MARK: - PackageRow

private struct PackageRow: View {
    let package: OutdatedPackage
    let isUpgrading: Bool
    let onUpgrade: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: package.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            Spacer()

            if isUpgrading {
                ProgressView()
                    .controlSize(.small)
            } else if isHovered {
                Button(L("Update")) { onUpgrade() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                HStack(spacing: 3) {
                    Text(verbatim: package.installedVersions.first ?? "?")
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                    Text(verbatim: package.currentVersion)
                }
                .font(.caption)
            }
        }
        .onHover { isHovered = $0 }
    }
}

// MARK: - ServiceRow

private struct ServiceRow: View {
    let entry: ServiceEntry
    let isToggling: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(entry.status.tintColor)
                .frame(width: 8, height: 8)

            Text(verbatim: entry.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            Spacer()

            if isToggling {
                ProgressView().controlSize(.small).frame(width: 36)
            } else {
                switch entry.status {
                case .started:
                    Button(L("Stop"), action: onStop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                case .stopped, .error:
                    Button(L("Start"), action: onStart)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.green)
                case .inactive, .unknown:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - InsightRow

private struct InsightRow: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: insight.severity.symbolName)
                .foregroundStyle(insight.severity.tintColor)
                .font(.caption)
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
        }
    }
}

// MARK: - DoctorWarningRow

private struct DoctorWarningRow: View {
    let warning: DoctorWarning

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: warning.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(warning.severity == .error ? .red : .orange)
                .font(.caption)
                .padding(.top, 1)

            Text(verbatim: warning.message)
                .font(.caption)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        case .updates: .yellow
        case .warning: .orange
        case .error: .red
        }
    }
}
