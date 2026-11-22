import BrewCore
import SwiftUI

/// The popover footer while an upgrade runs or has just ended (see `UpgradeActivity`): what's
/// being upgraded, what brew is doing and for how long, and — told apart by icon and words, not
/// only color — whether it's queued, gone quiet long enough to look stuck, failed, cancelled or done.
///
/// Two lines: the title, and under it in smaller text what brew is doing — or why it stopped. One
/// line held both, and the title, the position, the step and the time ran together; a quiet run's
/// warning got cut off. Every state, and the idle footer it replaces, has the same height
/// (`contentHeight`), so the list above doesn't move when a run starts, ends, goes quiet or fails.
/// No progress bar — brew reports a percentage only while downloading, so most of what a bar showed
/// was simulated.
struct UpgradeActivityBanner: View {
    let activity: UpgradeActivity
    let onShowLog: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    /// The footer's content height in every state, the idle footer's included (MenuBarView): two
    /// lines of text. States that differed (a failure's reason took a third line, done and
    /// cancelled had no buttons) made the list jump as a run ended.
    static let contentHeight: CGFloat = 34

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status {
                    Text(verbatim: status)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(explanation ?? status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .frame(height: Self.contentHeight)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        // Said out loud when it changes kind — a run ending, or going quiet — not every second.
        .onChange(of: announcementKey) { _, key in
            guard key != nil else { return }
            AccessibilityNotification.Announcement([title, explanation].compactMap(\.self).joined(separator: ". "))
                .post()
        }
    }

    // MARK: - Parts

    @ViewBuilder
    private var icon: some View {
        switch activity {
        case .running(_, _, _, _, nil, _, _), .cancelling:
            ProgressView().controlSize(.small)
        case .running:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.outdatedIcon)
        case .waiting:
            Image(systemName: "hourglass").foregroundStyle(Color.secondaryText)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.errorIcon)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(Color.secondaryText)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.successIcon)
        case .idle:
            EmptyView()
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            switch activity {
            case .running:
                logButton
                Button(L("Cancel"), action: onCancel)
            case .waiting:
                Button(L("Cancel"), action: onCancel)
            case .failed:
                logButton
                Button(L("Retry"), action: onRetry)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(L("Dismiss"))
                .accessibilityLabel(L("Dismiss"))
            case .idle, .cancelling, .cancelled, .done:
                EmptyView()
            }
        }
        .buttonStyle(.roomyBordered)
        .controlSize(.small)
    }

    /// An icon, not a second labeled button: next to Cancel or Retry, the log is the lesser action.
    private var logButton: some View {
        Button(action: onShowLog) {
            Image(systemName: "text.alignleft")
        }
        .buttonStyle(.borderless)
        .help(L("Show Log"))
        .accessibilityLabel(L("Show Log"))
    }

    // MARK: - Words

    private var targets: [String] {
        switch activity {
        case .idle: []
        case let .waiting(targets), let .running(targets, _, _, _, _, _, _), let .cancelling(targets),
             let .failed(targets, _, _), let .cancelled(targets), let .done(targets):
            targets
        }
    }

    /// "gh", or "38 packages".
    private var subject: String {
        targets.count == 1 ? targets[0] : L("\(targets.count) packages")
    }

    var title: String {
        switch activity {
        case .idle: ""
        case .waiting: L("Waiting for Homebrew")
        // The package brew is on, once it says, for a run of several; until then, how many.
        case let .running(_, _, _, _, _, position?, _):
            L("Upgrading \(position.current)")
        case .running, .cancelling:
            targets.count == 1 ? L("Upgrading \(targets[0])") : L("Upgrading \(targets.count) packages")
        case let .failed(_, wasAll, _):
            if wasAll {
                L("Upgrade All failed")
            } else if targets.count == 1 {
                L("Couldn't upgrade \(targets[0])")
            } else {
                L("Couldn't upgrade \(targets.count) packages")
            }
        case .cancelled: L("Upgrade cancelled")
        case .done: L("\(subject) upgraded")
        }
    }

    /// The second line: what brew is doing and for how long, why it's waiting, or why it failed —
    /// the whole of which is in the tooltip and the log.
    var status: String? {
        switch activity {
        case .idle: nil
        case .waiting: L("Starts when the other Homebrew command ends")
        case .cancelling: L("Cancelling…")
        case .running: note
        case let .failed(_, _, reason): Self.firstLine(of: reason)
        // The title says it all; centred in the same height.
        case .cancelled, .done: nil
        }
    }

    /// A reason's first line, without brew's "Error: " — the line says it failed already.
    static func firstLine(of reason: String) -> String {
        let line = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? reason
        return line.hasPrefix("Error: ") ? String(line.dropFirst("Error: ".count)) : line
    }

    /// The full sentence for a state the one line can only hint at — its tooltip, and what
    /// VoiceOver says.
    var explanation: String? {
        switch activity {
        case .waiting:
            L("Another Homebrew command is running. This one starts when it ends.")
        case let .running(_, step, progress, elapsed, quietFor?, position, downloaded):
            CommandRunMonitor.Snapshot(
                step: step, progress: progress, elapsed: elapsed, quietFor: quietFor,
                position: position, downloaded: downloaded
            ).quietExplanation
        case let .failed(_, _, reason):
            reason
        default:
            nil
        }
    }

    /// The short trailing note on the title's line: what brew is doing, and for how long (see
    /// `CommandRunMonitor.Snapshot.note`, which the Dashboard's sheets share).
    var note: String? {
        switch activity {
        case .cancelling:
            L("Cancelling…")
        case .waiting:
            L("In queue")
        case let .running(_, step, progress, elapsed, quietFor, position, downloaded):
            CommandRunMonitor.Snapshot(
                step: step, progress: progress, elapsed: elapsed, quietFor: quietFor,
                position: position, downloaded: downloaded
            ).note
        default:
            nil
        }
    }

    /// A stuck-looking run's status stands out in full strength next to the amber icon — amber text
    /// that small doesn't reach 4.5:1 in light mode. A caution, not an error: it may just be a long
    /// silent step.
    private var statusColor: Color {
        switch activity {
        case .running(_, _, _, _, .some, _, _): Color.primary
        default: Color.secondaryText
        }
    }

    /// Changes only when there's something worth announcing: a run ended, or went quiet.
    private var announcementKey: String? {
        switch activity {
        case .failed: "failed"
        case .done: "done"
        case .cancelled: "cancelled"
        case .running(_, _, _, _, .some, _, _): "quiet"
        default: nil
        }
    }
}

#Preview("Every state") {
    let states: [UpgradeActivity] = [
        .running(targets: ["gh"], step: .downloading, progress: 0.46, elapsed: 42, quietFor: nil),
        .running(
            targets: Array(repeating: "pkg", count: 23), step: .installing, progress: nil, elapsed: 126, quietFor: nil,
            position: UpgradeActivity.Position(current: "sdl3", number: 11, total: 23)
        ),
        .running(
            targets: Array(repeating: "pkg", count: 23), step: .compiling, progress: nil, elapsed: 400, quietFor: 75,
            position: UpgradeActivity.Position(current: "llvm", number: 3, total: 23)
        ),
        .waiting(targets: ["gh"]),
        .cancelling(targets: ["gh"]),
        .failed(targets: ["temurin"], wasAll: false, reason: "Error: a terminal is required to read the password"),
        .cancelled(targets: ["gh"]),
        .done(targets: Array(repeating: "pkg", count: 23)),
    ]
    VStack(spacing: 0) {
        ForEach(states.indices, id: \.self) { index in
            Divider()
            UpgradeActivityBanner(activity: states[index], onShowLog: {}, onCancel: {}, onRetry: {}, onDismiss: {})
        }
    }
    .frame(width: 380)
}
