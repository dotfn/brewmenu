import BrewCore
import Foundation

/// Follows one brew run — an upgrade, an install — to say what it's doing and whether it's still
/// doing anything: which package, which step, a real percentage when brew printed one, how long it
/// has taken, and whether it has gone quiet long enough to look stuck. Its output is one input;
/// what brew does without printing (downloads growing, processes using the CPU, build logs) is the
/// other, read by a `BrewActivitySampling` probe.
@MainActor
@Observable
final class CommandRunMonitor {
    /// What the run is about: one package, or every package of Upgrade All or a collection.
    private(set) var targets: [String] = []
    private(set) var startedAt: Date?
    /// The last line or progress update brew printed. The simulated progress doesn't count.
    private(set) var lastOutputAt: Date?
    /// The last sign of work besides printing: download bytes growing, a process of brew's using
    /// the CPU, or a build log growing. Quiet output alone, during a long build, isn't a hang.
    private(set) var lastActivityAt: Date?
    private(set) var endedAt: Date?
    /// The packages the run has started on, in order — from brew's `==> Upgrading <name>` lines
    /// (see `UpgradeActivity.startedPackage(fromLine:)`), or said by the caller (`started(_:)`).
    private(set) var startedPackages: [String] = []
    /// What the run's downloads have written so far (see `BrewActivitySample.downloadedBytes`).
    private(set) var downloadedBytes: Int64 = 0
    /// What the busiest process brew runs is doing (`curl`, `tar`, `clang`…).
    private(set) var busyWith: BrewBusyWith?

    /// Nil samples nothing, so tests stay deterministic unless they pass a probe.
    @ObservationIgnored private let probe: (any BrewActivitySampling)?
    @ObservationIgnored private var samplingTask: Task<Void, Never>?

    init(probe: (any BrewActivitySampling)? = nil) {
        self.probe = probe
    }

    var isRunning: Bool {
        startedAt != nil && endedAt == nil
    }

    func begin(targets: [String], at date: Date = .now) {
        self.targets = targets
        startedAt = date
        lastOutputAt = date
        lastActivityAt = nil
        endedAt = nil
        startedPackages = []
        downloadedBytes = 0
        busyWith = nil
        startSampling()
    }

    /// Brew printed something: a finished `line`, or (nil) an in-place progress update.
    func noteOutput(line: String? = nil, at date: Date = .now) {
        lastOutputAt = date
        if let line, let name = UpgradeActivity.startedPackage(fromLine: line) {
            started(name)
        }
    }

    /// For runs that start each package themselves — a collection's installs, one at a time.
    func started(_ name: String) {
        if !startedPackages.contains(name) { startedPackages.append(name) }
    }

    func end(at date: Date = .now) {
        samplingTask?.cancel()
        samplingTask = nil
        endedAt = date
    }

    // MARK: - Where it stands

    /// The run at `now` — a parameter rather than the clock, so a view can tick it every second and
    /// tests can ask about a minute from now without waiting one. `lastLine` is the newest line of
    /// its log, progress updates included.
    func snapshot(at now: Date, lastLine: String?) -> Snapshot {
        let start = startedAt ?? now
        // Quiet only when nothing at all says brew is working: no output, and no download growing
        // or process busy since then.
        let lastSign = [lastOutputAt ?? start, lastActivityAt ?? start].max() ?? start
        let quiet = now.timeIntervalSince(lastSign)
        let step = UpgradeActivity.step(fromLastLine: lastLine, busyWith: busyWith)
        return Snapshot(
            step: step,
            // Only a percentage brew printed (its download block, or curl's meter) — never a
            // simulated curve.
            progress: step == .downloading ? lastLine.flatMap(CommandProgress.parsePercent(from:)) : nil,
            elapsed: now.timeIntervalSince(start),
            quietFor: quiet >= UpgradeActivity.quietThreshold ? quiet : nil,
            position: position,
            downloaded: downloadedBytes > 0 ? downloadedBytes : nil
        )
    }

    /// Which of several packages the run is on. Nil for a single package (whatever shows it already
    /// says which), and until the first one starts. Capped at the total: an upgrade can also take
    /// in dependents.
    var position: UpgradeActivity.Position? {
        guard targets.count > 1, let current = startedPackages.last else { return nil }
        return UpgradeActivity.Position(
            current: current,
            number: min(startedPackages.count, targets.count),
            total: targets.count
        )
    }

    struct Snapshot: Equatable {
        var step: UpgradeActivity.Step
        /// A real download percentage from brew's own output, nil when it gave none.
        var progress: Double?
        var elapsed: TimeInterval
        /// Set once brew has shown no sign of work for `UpgradeActivity.quietThreshold`.
        var quietFor: TimeInterval?
        var position: UpgradeActivity.Position?
        var downloaded: Int64?

        /// The short note a status line ends on: "2 of 38 · Downloading… 46% · 0:42",
        /// "No output for 1 minute".
        var note: String {
            if let quietFor {
                return [position.map(Self.count), L("No output for \(Self.minutes(quietFor))")]
                    .compactMap(\.self).joined(separator: " · ")
            }
            let time = Duration.seconds(Int(elapsed)).formatted(.time(pattern: .minuteSecond))
            // Both real, so they go with the step they belong to: brew's own percentage first, the
            // bytes read from its in-progress downloads when it gave none.
            let amount = progress.map { $0.formatted(.percent.precision(.fractionLength(0))) }
                ?? downloaded.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            let bytes = step == .downloading ? amount : nil
            // "Preparing" and "Working" say nothing a spinner doesn't; the time alone does.
            // "Downloading… 0:42", or "Downloading… 23.4 MB · 0:42" once there's an amount.
            let doing = Self.stepText(step).map { text in bytes.map { "\(text) \($0) ·" } ?? text }
            let timed = doing.map { "\($0) \(time)" } ?? time
            return [position.map(Self.count), timed].compactMap(\.self).joined(separator: " · ")
        }

        /// The full sentence a quiet run's note can only hint at — its tooltip, and what VoiceOver
        /// says.
        var quietExplanation: String? {
            quietFor.map { L("No output for \(Self.minutes($0)). Homebrew may be stuck.") }
        }

        /// "3 of 38" — real progress through a run of several.
        static func count(_ position: UpgradeActivity.Position) -> String {
            L("\(position.number) of \(position.total)")
        }

        static func minutes(_ interval: TimeInterval) -> String {
            Duration.seconds(max(1, Int(interval / 60)) * 60).formatted(.units(allowed: [.minutes], width: .wide))
        }

        static func stepText(_ step: UpgradeActivity.Step) -> String? {
            switch step {
            case .preparing, .working: nil
            case .downloading: L("Downloading…")
            case .unpacking: L("Unpacking…")
            case .compiling: L("Compiling…")
            case .installing: L("Installing…")
            case .cleaningUp: L("Cleaning up…")
            }
        }
    }

    // MARK: - Sampling

    /// CPU seconds per wall-clock second above which brew counts as working: well over an idle
    /// process's background ticks, well under any real step.
    private static let busyCPUPerSecond: TimeInterval = 0.05

    /// Once a second while the run lasts: brew's downloads, processes and build logs, read from
    /// outside.
    private func startSampling() {
        samplingTask?.cancel()
        guard let probe, let start = startedAt else { return }
        samplingTask = Task { [weak self] in
            await probe.start(at: start)
            var lastCPUTime: TimeInterval?
            var lastBuildLogBytes: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let sample = await probe.sample()
                guard !Task.isCancelled, let self else { return }
                let cpuBusy = lastCPUTime.map { sample.cpuTime - $0 > Self.busyCPUPerSecond } ?? false
                let buildLogGrew = sample.buildLogBytes > lastBuildLogBytes
                if sample.downloadedBytes > downloadedBytes || cpuBusy || buildLogGrew {
                    lastActivityAt = Date()
                }
                lastBuildLogBytes = sample.buildLogBytes
                downloadedBytes = max(downloadedBytes, sample.downloadedBytes)
                busyWith = cpuBusy ? sample.busyWith : nil
                lastCPUTime = sample.cpuTime
            }
        }
    }
}
