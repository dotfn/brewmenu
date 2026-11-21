import BrewCore
import SwiftUI

/// Shared install-progress sheet — shown for both a pack install (`installPack`) and a
/// single ad-hoc install (`installSingle`), driven by the same `isInstalling`/`installLog`
/// pair either way. Attached once, at `DashboardView`'s root, so it appears regardless of
/// which section (Search Results, Discover, a collection, …) kicked the install off.
struct InstallLogView: View {
    let dashboardViewModel: DashboardViewModel

    /// Collapsed by default — most installs just work, so the raw brew output is
    /// noise. Auto-expanded on failure below, since that's exactly when someone
    /// needs to see it.
    @State private var showDetails = false

    private var isRunning: Bool {
        dashboardViewModel.isInstallRunning
    }

    private var isCancelling: Bool {
        dashboardViewModel.isCancellingInstall
    }

    private var failures: [(name: String, message: String)] {
        dashboardViewModel.installSessionFailures
    }

    private var hasFailures: Bool {
        !failures.isEmpty
    }

    private var phase: DashboardViewModel.InstallPhase {
        dashboardViewModel.installPhase
    }

    /// "Done" only for a run that worked — it used to sit next to the red failure icon too, and
    /// end a cancelled run on a green check.
    private var title: String {
        switch phase {
        case .running: L("Installing…")
        case .cancelling: L("Cancelling…")
        case .cancelled: L("Install cancelled")
        case .failed: L("Install failed")
        case .done: L("Done")
        }
    }

    private var symbol: String {
        switch phase {
        case .running, .cancelling: "shippingbox"
        case .cancelled: "stop.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch phase {
        case .running, .cancelling: BrewTheme.accent
        case .cancelled: .secondary
        case .failed: Color.errorIcon
        case .done: Color.successIcon
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(tint)
                        .symbolRenderingMode(.hierarchical)
                        // The title next to it says the same, in words.
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.headline)
                    if isCancelling {
                        // The title already says it.
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
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
                    // Still "Cancel" while brew stops: a focused button reading "Done" next to
                    // "Cancelling…" said the opposite of what was happening.
                    Button(isRunning || isCancelling ? L("Cancel") : L("Done")) {
                        if isRunning {
                            dashboardViewModel.cancelInstall()
                        } else {
                            dashboardViewModel.dismissInstallSheet()
                        }
                    }
                    .buttonStyle(.roomyBordered)
                    .controlSize(.small)
                    .keyboardShortcut(isRunning ? .cancelAction : .defaultAction)
                    // brew is still stopping: closing now would let a new install queue behind it
                    // with nothing on screen saying why it isn't starting.
                    .disabled(isCancelling)
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

                // The reason, up front — same treatment as the upgrade sheet. It used to sit
                // only in the log, behind "Show more".
                if !isRunning, !isCancelling, let failure = failures.first {
                    Text(failures.count == 1 ? failure.message : "\(failure.name): \(failure.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button(L("Copy error")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                dashboardViewModel.installLog.joined(separator: "\n"),
                                forType: .string
                            )
                        }
                        .buttonStyle(.roomyBordered)
                        .controlSize(.small)
                        .accessibilityIdentifier(AccessibilityID.installSheetCopyError)
                        AskAIMenu {
                            AIPrompt.failedCommand(dashboardViewModel.installFailureReport(name: failure.name))
                        }
                    }
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
        // VoiceOver users, so say it out loud too — once brew has really stopped: Cancel ends
        // `isRunning` at once, and this used to announce "Install complete" right then.
        .onChange(of: isRunning || isCancelling) { _, busy in
            guard !busy else { return }
            AccessibilityNotification.Announcement(phase == .done ? L("Install complete") : title).post()
        }
        .onChange(of: isCancelling) { _, cancelling in
            if cancelling { AccessibilityNotification.Announcement(L("Cancelling…")).post() }
        }
    }
}
