import SwiftUI

struct InstallPacksView: View {
    let dashboardViewModel: DashboardViewModel

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 12)]

    var body: some View {
        // No header here — the window's navigationTitle already reads "Install Packs"
        // immediately above.
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(dashboardViewModel.installPacks) { pack in
                        InstallPackCard(pack: pack, dashboardViewModel: dashboardViewModel)
                    }
                }
                .padding()
            }
        }
        // Same "title + count" header shape as every other list-backed section.
        .navigationSubtitle(dashboardViewModel.installPacks
            .count == 1 ? L("1 pack") : L("\(dashboardViewModel.installPacks.count) packs"))
    }
}

struct InstallPackCard: View {
    let pack: InstallPack
    let dashboardViewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: pack.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer()
                Text(pack.packageCount == 1 ? L("1 package") : L("\(pack.packageCount) packages"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(pack.title)
                .font(.headline)
            Text(pack.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text((pack.formulae + pack.casks).joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button(L("Install Pack")) {
                dashboardViewModel.installPack(pack)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(dashboardViewModel.isInstalling)
            .help(dashboardViewModel.isInstalling ? L("Another install is in progress") : "")
            .accessibilityLabel(L("Install \(pack.title) pack"))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// Shared install-progress sheet — shown for both a pack install (`installPack`) and a
/// single ad-hoc install (`installSingle`), driven by the same `isInstalling`/`installLog`
/// pair either way. Attached once, at `DashboardView`'s root, so it appears regardless of
/// which section (Search Results, Trending, Install Packs, …) kicked the install off.
struct InstallLogView: View {
    let dashboardViewModel: DashboardViewModel

    /// Collapsed by default — most installs just work, so the raw brew output is
    /// noise. Auto-expanded on failure below, since that's exactly when someone
    /// needs to see it.
    @State private var showDetails = false

    private var isRunning: Bool {
        dashboardViewModel.isInstallRunning
    }

    private var hasFailures: Bool {
        !dashboardViewModel.failedInstallNames.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if isRunning {
                        Text(L("Installing…"))
                            .font(.headline)
                        if let progress = dashboardViewModel.installProgress {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        Image(systemName: hasFailures ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(hasFailures ? .red : .green)
                        Text(L("Done"))
                            .font(.headline)
                    }
                    Spacer()
                    // While running: stops the process but leaves the log on screen. Once
                    // finished: an explicit close — the sheet no longer dismisses itself the
                    // instant brew exits, so caveats/warnings in the log stay readable until
                    // the user has actually seen them.
                    Button(isRunning ? L("Cancel") : L("Done")) {
                        if isRunning {
                            dashboardViewModel.cancelInstall()
                        } else {
                            dashboardViewModel.dismissInstallSheet()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(isRunning ? .cancelAction : .defaultAction)
                }

                // `installProgress` comes from curl's own percentage meter (see
                // `DashboardViewModel.appendInstallProgress`) — real progress, not a
                // simulated fill. Always a determinate 0...1 bar, defaulting to empty
                // before the first percentage arrives (or for formula installs that
                // never report one) — macOS's indeterminate style renders as a small
                // sliding chunk rather than a 0-100 fill, which read as broken/stuck.
                if isRunning {
                    let progress = dashboardViewModel.installProgress ?? 0
                    // Curl reports in whole-percent jumps — animate the fill between
                    // them so it reads as one continuous advance, not a stepladder.
                    ProgressView(value: progress).progressViewStyle(.linear)
                        .animation(.linear(duration: 0.2), value: progress)
                }

                Button {
                    showDetails.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(showDetails ? L("Hide details") : L("Show more"))
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            if showDetails {
                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(dashboardViewModel.installLog.enumerated()), id: \.offset) { index, line in
                                Text(verbatim: line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(lineColor(line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: dashboardViewModel.installLog.count) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(width: 480, height: showDetails ? 360 : nil)
        // A failed install is exactly when the raw log matters — surface it
        // automatically instead of leaving the user to notice the toggle.
        .onChange(of: hasFailures) { _, failed in
            if failed { showDetails = true }
        }
    }

    private func lineColor(_ line: String) -> Color {
        if line.hasPrefix("✗") { return .red }
        if line.hasPrefix("⚠") { return .orange }
        if line.hasPrefix("✓") { return .green }
        return .primary
    }
}
