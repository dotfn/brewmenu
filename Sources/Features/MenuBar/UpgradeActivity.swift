import BrewCore
import Foundation

/// Where an upgrade run stands, as the popover tells it: running (and how far), queued behind
/// another Homebrew command, quiet long enough to look stuck, or how it ended. The popover used to
/// show a bare spinner and "Upgrading…" — nothing to tell progress from a hang — and said nothing
/// at all when an upgrade failed, beyond the header turning red.
enum UpgradeActivity: Equatable {
    case idle
    /// Started, but behind another Homebrew command holding its lock.
    case waiting(targets: [String])
    /// `progress` is a real download percentage from brew's own output, nil when it gave none.
    /// `quietFor` is set once brew has shown no sign of work for `quietThreshold` — no output, no
    /// download bytes, no CPU in what it runs (see `BrewActivityProbe`). `position` is which package
    /// of several brew is on, once it says (see `startedPackage(fromLine:)`). `downloaded` is what
    /// the run's downloads have written so far.
    case running(
        targets: [String],
        step: Step,
        progress: Double?,
        elapsed: TimeInterval,
        quietFor: TimeInterval?,
        position: Position? = nil,
        downloaded: Int64? = nil
    )
    case cancelling(targets: [String])
    case failed(targets: [String], wasAll: Bool, reason: String)
    case cancelled(targets: [String])
    case done(targets: [String])

    /// The package brew is upgrading now, and its place in the run: 3 of 38. Counted from brew's own
    /// per-package headings — real, unlike the download percentage's simulated stretches.
    struct Position: Equatable {
        let current: String
        let number: Int
        let total: Int
    }

    /// What brew is doing: from its last line of output, or — when that's no more specific than
    /// "working" — from the process it's running (see `step(fromLastLine:busyWith:)`).
    enum Step: Equatable {
        case preparing, downloading, unpacking, compiling, installing, cleaningUp, working
    }

    /// The line's step, unless it only says brew is busy: then what its busiest process is for. A
    /// build from source prints little while `clang` runs for minutes.
    static func step(fromLastLine line: String?, busyWith: BrewBusyWith?) -> Step {
        let fromLine = step(fromLastLine: line)
        guard fromLine == .working || fromLine == .preparing, let busyWith else { return fromLine }
        return switch busyWith {
        case .downloading: .downloading
        case .unpacking: .unpacking
        case .compiling: .compiling
        case .installing: .installing
        }
    }

    /// Long enough that a download or an install step would have printed something.
    static let quietThreshold: TimeInterval = 60
    /// How long a run that ended well stays up before the footer goes back to normal. A failure
    /// stays until it's dismissed or retried.
    static let outcomeVisibleFor: TimeInterval = 6

    /// The package a line says brew has started on, or nil. Homebrew prints `==> Upgrading <name>`
    /// once per package, formula or cask (`upgrade.rb`, `cask/upgrade.rb`), the name possibly with
    /// its tap (`user/repo/name`). Not counted: the summaries (`==> Upgrading 30 outdated
    /// packages:`, `==> Upgrading 2 dependents of upgraded formulae:`) and a dependency pulled in
    /// along the way (`==> Upgrading gh dependency: …`) — none of them is a single bare name.
    static func startedPackage(fromLine line: String) -> String? {
        let prefix = "==> Upgrading "
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let rest = trimmed.dropFirst(prefix.count)
        guard !rest.isEmpty, !rest.contains(" "), !rest.hasSuffix(":"), rest.first?.isNumber == false
        else { return nil }
        return String(rest)
    }

    /// Reads brew's own headings ("==> Downloading …", "==> Pouring …", "🍺 …") and its
    /// in-place download percentages.
    static func step(fromLastLine line: String?) -> Step {
        guard let line = line?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return .preparing }
        if CommandProgress.parsePercent(from: line) != nil { return .downloading }
        let lowered = line.lowercased()
        if lowered.contains("updating homebrew") || lowered.hasPrefix("==> upgrading")
            || lowered.hasPrefix("==> auto-updating")
        {
            return .preparing
        }
        if lowered.hasPrefix("==> downloading") || lowered.hasPrefix("==> fetching") { return .downloading }
        if lowered.hasPrefix("==> pouring") || lowered.hasPrefix("==> installing")
            || lowered.hasPrefix("==> linking") || lowered.hasPrefix("🍺")
        {
            return .installing
        }
        if lowered.contains("brew cleanup") || lowered.hasPrefix("removing:") { return .cleaningUp }
        return .working
    }
}

extension MenuBarViewModel {
    /// The run's state at `now` — a parameter rather than the clock, so the footer can tick it
    /// every second and tests can ask about a minute from now without waiting one.
    func upgradeActivity(at now: Date) -> UpgradeActivity {
        if isCancellingUpgrade { return .cancelling(targets: upgradeTargets) }
        if isRunningAnyUpgrade {
            if upgradeLog.isEmpty, isWaitingBehindBrew { return .waiting(targets: upgradeTargets) }
            let start = upgradeStartedAt ?? now
            // Quiet only when nothing at all says brew is working: no output, and no download
            // growing or process busy since then.
            let lastSign = [upgradeLastOutputAt ?? start, upgradeLastActivityAt ?? start].max() ?? start
            let quiet = now.timeIntervalSince(lastSign)
            let step = UpgradeActivity.step(fromLastLine: upgradeLog.last, busyWith: upgradeBusyWith)
            return .running(
                targets: upgradeTargets,
                step: step,
                // Only a percentage brew printed (its download block, or curl's meter) — never the
                // simulated curve `upgradeProgress` falls back to.
                progress: step == .downloading ? upgradeLog.last.flatMap(CommandProgress.parsePercent(from:)) : nil,
                elapsed: now.timeIntervalSince(start),
                quietFor: quiet >= UpgradeActivity.quietThreshold ? quiet : nil,
                position: upgradePosition,
                downloaded: upgradeDownloadedBytes > 0 ? upgradeDownloadedBytes : nil
            )
        }
        guard let ended = upgradeEndedAt, !upgradeOutcomeDismissed else { return .idle }
        if let upgradeFailure {
            return .failed(targets: upgradeTargets, wasAll: lastUpgradeWasAll, reason: upgradeFailure)
        }
        guard now.timeIntervalSince(ended) < UpgradeActivity.outcomeVisibleFor else { return .idle }
        return upgradeWasCancelled ? .cancelled(targets: upgradeTargets) : .done(targets: upgradeTargets)
    }

    /// Which of several packages brew is on. Nil for a single package (its row says which), and
    /// until brew names the first one. Capped at the total: a run can also upgrade dependents.
    private var upgradePosition: UpgradeActivity.Position? {
        guard upgradeTargets.count > 1, let current = upgradeStartedPackages.last else { return nil }
        let total = upgradeTargets.count
        return UpgradeActivity.Position(
            current: current,
            number: min(upgradeStartedPackages.count, total),
            total: total
        )
    }

    /// Why upgrading `name` from its own row just failed — nil for any other row, and after an
    /// Upgrade All, which can't tell which package brew stopped on.
    func upgradeFailure(forPackage name: String) -> String? {
        guard let upgradeFailure, !upgradeOutcomeDismissed, !lastUpgradeWasAll, upgradeTargets == [name]
        else { return nil }
        return upgradeFailure
    }
}
