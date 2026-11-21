import BrewCore
import SwiftUI

/// The popover footer while an upgrade runs or has just ended (see `UpgradeActivity`): what's
/// being upgraded, what brew is doing and for how long, and — told apart by icon and words, not
/// only color — whether it's queued, gone quiet long enough to look stuck, failed, cancelled or done.
///
/// One line, the same height as the footer it replaces (`lineHeight`), so the list above doesn't
/// move when a run starts, ends, or goes quiet; only a failure adds a line, for its reason. No
/// progress bar — brew reports a percentage only while downloading, so most of what a bar showed
/// was simulated.
struct UpgradeActivityBanner: View {
    let activity: UpgradeActivity
    let onShowLog: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    /// The footer's line height in every state, the idle footer's included (MenuBarView): the
    /// height of a small bordered button. States without buttons (done, cancelled) measured 4 pt
    /// shorter, and the list jumped twice as a run ended.
    static let lineHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                icon
                    .frame(width: 16, height: 16)
                Text(verbatim: title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let note {
                    Text(verbatim: note)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(noteColor)
                        .lineLimit(1)
                        .help(explanation ?? note)
                }
                buttons
            }
            .frame(height: Self.lineHeight)
            if let detail {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(detailColor)
                    .lineLimit(2)
                    .help(detail)
                    // Under the title, past the icon.
                    .padding(.leading, 24)
            }
        }
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
            wasAll || targets.count != 1 ? L("Upgrade All failed") : L("Couldn't upgrade \(targets[0])")
        case .cancelled: L("Upgrade cancelled")
        case .done: L("\(subject) upgraded")
        }
    }

    var detail: String? {
        switch activity {
        case .idle, .done, .cancelled:
            nil
        case .waiting, .cancelling, .running:
            nil
        case let .failed(_, _, reason):
            reason
        }
    }

    /// The full sentence for a state the one line can only hint at — its tooltip, and what
    /// VoiceOver says.
    var explanation: String? {
        switch activity {
        case .waiting:
            L("Another Homebrew command is running. This one starts when it ends.")
        case let .running(_, _, _, _, quietFor?, _, _):
            L("No output for \(Self.minutes(quietFor)). Homebrew may be stuck.")
        case let .failed(_, _, reason):
            reason
        default:
            nil
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "3 of 38" — real progress through a run of several, from brew's own per-package headings.
    private static func count(_ position: UpgradeActivity.Position) -> String {
        L("\(position.number) of \(position.total)")
    }

    private static func minutes(_ interval: TimeInterval) -> String {
        Duration.seconds(max(1, Int(interval / 60)) * 60).formatted(.units(allowed: [.minutes], width: .wide))
    }

    /// The short trailing note on the title's line: what brew is doing, and for how long.
    var note: String? {
        switch activity {
        case .cancelling:
            return L("Cancelling…")
        case .waiting:
            return L("In queue")
        case let .running(_, _, _, _, quietFor?, position, _):
            return [position.map(Self.count), L("No output for \(Self.minutes(quietFor))")]
                .compactMap(\.self).joined(separator: " · ")
        case let .running(_, step, progress, elapsed, _, position, downloaded):
            let time = Duration.seconds(Int(elapsed)).formatted(.time(pattern: .minuteSecond))
            // Both real, so they go with the step they belong to: brew's own percentage first, the
            // bytes read from its in-progress downloads when it gave none.
            let amount = progress.map { $0.formatted(.percent.precision(.fractionLength(0))) }
                ?? downloaded.map(Self.bytes)
            let bytes = step == .downloading ? amount : nil
            // "Preparing" and "Working" say nothing the spinner doesn't; the time alone does.
            // "Downloading… 0:42", or "Downloading… 23.4 MB · 0:42" once there are bytes.
            let doing = stepText(step).map { text in bytes.map { "\(text) \($0) ·" } ?? text }
            let timed = doing.map { "\($0) \(time)" } ?? time
            return [position.map(Self.count), timed].compactMap(\.self).joined(separator: " · ")
        default:
            return nil
        }
    }

    private var detailColor: Color {
        Color.secondaryText
    }

    /// A stuck-looking run's note is a caution, not an error: it may just be a long silent step.
    private var noteColor: Color {
        switch activity {
        case .running(_, _, _, _, .some, _, _): Color.primary
        default: Color.secondaryText
        }
    }

    private func stepText(_ step: UpgradeActivity.Step) -> String? {
        switch step {
        case .preparing, .working: nil
        case .downloading: L("Downloading…")
        case .unpacking: L("Unpacking…")
        case .compiling: L("Compiling…")
        case .installing: L("Installing…")
        case .cleaningUp: L("Cleaning up…")
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
