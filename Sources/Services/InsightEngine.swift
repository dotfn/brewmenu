import Foundation

/// Pure function: takes snapshots, returns insights. No filesystem, no network.
/// All logic is in static methods so it's trivially testable with synthetic fixtures.
enum InsightEngine {

    static func insights(from snapshots: [Snapshot]) -> [Insight] {
        guard !snapshots.isEmpty else { return [] }
        let latest = snapshots[0] // snapshots are newest-first

        var result: [Insight] = []

        if let i = staleUpdate(in: snapshots) { result.append(i) }
        if let i = doctorNotRun(latest: latest) { result.append(i) }
        if let i = cleanupPending(in: snapshots) { result.append(i) }
        if let i = accumulatedUpdates(latest: latest) { result.append(i) }
        if let i = serviceDown(in: snapshots) { result.append(i) }
        if let i = abandonedCask(in: snapshots) { result.append(i) }

        return result
    }

    // MARK: - Individual rules

    /// A package that has been outdated for more than 14 days without being upgraded.
    static func staleUpdate(in snapshots: [Snapshot]) -> Insight? {
        guard snapshots.count >= 2 else { return nil }

        let latest = snapshots[0]
        guard !latest.outdatedPackages.isEmpty else { return nil }

        let cutoff = Date().addingTimeInterval(-14 * 86400)
        let latestNames = Set(latest.outdatedPackages.map(\.name))

        var firstSeen: [String: Date] = [:]
        for snapshot in snapshots.reversed() {
            let names = Set(snapshot.outdatedPackages.map(\.name))
            for name in names where latestNames.contains(name) && firstSeen[name] == nil {
                firstSeen[name] = snapshot.timestamp
            }
        }

        let stale = firstSeen.filter { $0.value < cutoff }
        guard !stale.isEmpty else { return nil }

        let names = stale.keys.sorted().prefix(3).joined(separator: ", ")
        let suffix = stale.count > 3 ? L(" and \(stale.count - 3) more") : ""
        return Insight(
            id: "stale-updates",
            severity: .warning,
            title: L("Stale updates"),
            detail: L("\(names + suffix) – outdated for more than 14 days.")
        )
    }

    /// Doctor hasn't run in more than 30 days.
    /// Every snapshot represents a doctor run, so we check the latest snapshot's age.
    static func doctorNotRun(latest: Snapshot) -> Insight? {
        let daysSinceLatest = Date().timeIntervalSince(latest.timestamp) / 86400
        guard daysSinceLatest > 30 else { return nil }
        return Insight(
            id: "doctor-not-run",
            severity: .warning,
            title: L("brew doctor hasn't run recently"),
            detail: L("Last health check was more than 30 days ago.")
        )
    }

    /// A service that was running in the previous snapshot is now stopped or errored.
    static func serviceDown(in snapshots: [Snapshot]) -> Insight? {
        guard snapshots.count >= 2 else { return nil }
        let latest = snapshots[0]
        let previous = snapshots[1]

        let previousStarted = Set(previous.services.filter { $0.status == .started }.map(\.name))
        let downNow = latest.services.filter {
            previousStarted.contains($0.name) && ($0.status == .stopped || $0.status == .error)
        }
        guard !downNow.isEmpty else { return nil }

        let names = downNow.map(\.name).sorted().prefix(3).joined(separator: ", ")
        let suffix = downNow.count > 3 ? L(" and \(downNow.count - 3) more") : ""
        let plural = downNow.count > 1
        return Insight(
            id: "service-down",
            severity: .critical,
            title: plural ? L("Services down") : L("Service down"),
            detail: L("\(names + suffix) stopped running.")
        )
    }

    /// More than 1 GB reclaimable via cleanup, with no cleanup detected in the past 14 days.
    /// A cleanup is inferred from a snapshot where cleanupBytesReclaimable == 0.
    static func cleanupPending(in snapshots: [Snapshot]) -> Insight? {
        guard !snapshots.isEmpty else { return nil }
        let latest = snapshots[0]

        let oneGiB: Int64 = 1_073_741_824
        guard latest.cleanupBytesReclaimable > oneGiB else { return nil }

        let cutoff = Date().addingTimeInterval(-14 * 86400)
        // Snapshots are newest-first; find the most recent one where cleanup was done (bytes == 0).
        let lastCleanup = snapshots.first { $0.cleanupBytesReclaimable == 0 }

        // If there was a cleanup in the past 14 days, don't fire.
        if let last = lastCleanup, last.timestamp > cutoff { return nil }

        let formatted = ByteCountFormatter.string(
            fromByteCount: latest.cleanupBytesReclaimable,
            countStyle: .file
        )
        return Insight(
            id: "cleanup-pending",
            severity: .warning,
            title: L("Cleanup pending"),
            detail: L("\(formatted) reclaimable by running brew cleanup.")
        )
    }

    /// Casks that have been at the same installed version for 14+ days with no available update.
    /// The SPECT targets 90 days; 14 days is used since snapshots are retained for only 30 days.
    static func abandonedCask(in snapshots: [Snapshot]) -> Insight? {
        guard snapshots.count >= 2 else { return nil }
        let newest = snapshots[0]
        // snapshots are newest-first, so last is the oldest
        let oldest = snapshots[snapshots.count - 1]

        let span = newest.timestamp.timeIntervalSince(oldest.timestamp)
        guard span >= 14 * 86400 else { return nil }
        guard !newest.installedCasks.isEmpty else { return nil }

        let outdatedNames = Set(newest.outdatedPackages.map(\.name))
        let oldestVersions = Dictionary(
            uniqueKeysWithValues: oldest.installedCasks.map { ($0.name, $0.version) }
        )

        let stale = newest.installedCasks.filter { cask in
            guard let oldVersion = oldestVersions[cask.name] else { return false }
            return oldVersion == cask.version && !outdatedNames.contains(cask.name)
        }
        guard !stale.isEmpty else { return nil }

        let names = stale.prefix(3).map(\.name).sorted().joined(separator: ", ")
        let suffix = stale.count > 3 ? L(" and \(stale.count - 3) more") : ""
        let plural = stale.count > 1
        let days = Int(span / 86400)
        return Insight(
            id: "abandoned-cask",
            severity: .info,
            title: plural ? L("Casks without updates") : L("Cask without updates"),
            detail: L("\(names + suffix) – stable for more than \(days) days with no new versions.")
        )
    }

    /// More than 20 packages accumulated without upgrading.
    static func accumulatedUpdates(latest: Snapshot) -> Insight? {
        let count = latest.outdatedPackages.count
        guard count > 20 else { return nil }
        return Insight(
            id: "accumulated-updates",
            severity: .critical,
            title: L("Many updates accumulated"),
            detail: L("\(count) packages are waiting to be upgraded.")
        )
    }
}
