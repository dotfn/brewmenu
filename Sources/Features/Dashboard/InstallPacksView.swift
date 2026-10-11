import BrewCore
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
                    Image(systemName: isRunning ? "shippingbox" : (hasFailures ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                        .font(.title3)
                        .foregroundStyle(isRunning ? BrewTheme.accent : (hasFailures ? .red : .green))
                        .symbolRenderingMode(.hierarchical)
                    Text(isRunning ? L("Installing…") : L("Done"))
                        .font(.headline)
                    if isRunning, let progress = dashboardViewModel.installProgress {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
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
                    CommandProgressBar(progress: dashboardViewModel.installProgress ?? 0)
                }

                CommandLogDisclosureButton(showDetails: $showDetails)
            }
            .padding()

            if showDetails {
                Divider()
                CommandLogDetail(lines: dashboardViewModel.installLog)
            }
        }
        .frame(width: 480, height: showDetails ? 360 : nil)
        // A failed install is exactly when the raw log matters — surface it
        // automatically instead of leaving the user to notice the toggle.
        .onChange(of: hasFailures) { _, failed in
            if failed { showDetails = true }
        }
        // Same as the upgrade sheet: the visual result alone is easy to miss for
        // VoiceOver users, so say it out loud too.
        .onChange(of: isRunning) { _, running in
            guard !running else { return }
            AccessibilityNotification.Announcement(
                hasFailures ? L("Install failed") : L("Install complete")
            ).post()
        }
    }
}
