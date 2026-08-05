import Foundation

@MainActor
@Observable
final class MenuBarViewModel {
    @ObservationIgnored private let service: any BrewServicing
    @ObservationIgnored private let notifier: BrewNotifier?
    @ObservationIgnored private let historyStore: HistoryStore?
    @ObservationIgnored private var upgradeTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var autoremoveTask: Task<Void, Never>?

    private(set) var status: MenuBarStatus = .initializing
    private(set) var outdatedPackages: [OutdatedPackage] = []
    private(set) var doctorWarnings: [DoctorWarning] = []
    private(set) var insights: [Insight] = []
    private(set) var services: [ServiceEntry] = []
    private(set) var upgradeLog: [String] = []
    private(set) var cleanupLog: [String] = []
    private(set) var autoremoveLog: [String] = []
    /// Kept alongside `insights` (not parsed back out of the "unused-dependencies"
    /// insight's formatted text) so the removal confirmation dialog can list the
    /// exact formulae that would be uninstalled.
    private(set) var autoremovableFormulae: [String] = []
    private(set) var isRefreshing: Bool = false
    private(set) var isUpgrading: Bool = false
    private(set) var isCleaningUp: Bool = false
    private(set) var isRemovingUnusedDependencies: Bool = false
    private(set) var lastChecked: Date? = nil
    private(set) var togglingServices: Set<String> = []
    private(set) var upgradingPackages: Set<String> = []
    private(set) var needsRestart: Bool = false

    /// All services except unknown — includes inactive so users can start them from the UI.
    var visibleServices: [ServiceEntry] {
        services.filter { $0.status != .unknown }
    }

    /// Whether there's anything the user might want to act on right now — drives
    /// whether the menu bar icon can hide itself (see `AppSettings.hideMenuBarIconWhenClear`).
    /// `.initializing` counts as "yes" so the icon doesn't vanish during the first
    /// bootstrap check, before there's ever been a confirmed "all clear".
    var hasSomethingToAttendTo: Bool {
        if case .initializing = status { return true }
        if needsRestart { return true }
        if !insights.isEmpty { return true }
        if case .ok = status { return false }
        return true // .updates, .warning, .error
    }

    init(service: any BrewServicing, notifier: BrewNotifier? = nil, historyStore: HistoryStore? = nil) {
        self.service = service
        self.notifier = notifier
        self.historyStore = historyStore
    }

    // MARK: - Public API (sync — called from SwiftUI body)

    func start(customBrewPath: String? = nil) {
        Task { await performBootstrap(customBrewPath: customBrewPath) }
    }

    func refresh() {
        guard !isRefreshing, !isUpgrading else { return }
        Task {
            isRefreshing = true
            defer { isRefreshing = false }
            do {
                try await service.runUpdate()
                try await fetchAndUpdateState()
            } catch {
                status = .error(message(from: error))
            }
        }
    }

    func upgradeAll() {
        guard !isUpgrading, !isRefreshing else { return }
        upgradeTask = Task { await performUpgradeAll() }
    }

    func upgradePackage(_ name: String) {
        guard !isUpgrading, !upgradingPackages.contains(name) else { return }
        upgradingPackages.insert(name)
        Task {
            defer { upgradingPackages.remove(name) }
            do {
                try await service.runUpgrade(name)
                try await fetchAndUpdateState()
                if name == "brewmenu" { needsRestart = true }
            } catch {
                status = .error(message(from: error))
            }
        }
    }

    func cancelUpgrade() {
        upgradeTask?.cancel()
        upgradeTask = nil
    }

    /// Reclaims disk space via `brew cleanup` — deletes old package versions and
    /// cached downloads, so unlike `upgradeAll` this needs an explicit confirmation
    /// in the UI before it's ever called.
    func cleanUp() {
        guard !isCleaningUp, !isUpgrading, !isRefreshing else { return }
        cleanupTask = Task { await performCleanUp() }
    }

    func cancelCleanUp() {
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    /// Uninstalls formulae `brew autoremove` reports as no longer needed by
    /// anything — unlike `cleanUp` this removes whole packages, not just cached
    /// files, so it needs its own, stronger confirmation in the UI.
    func removeUnusedDependencies() {
        guard !isRemovingUnusedDependencies, !isUpgrading, !isRefreshing, !isCleaningUp else { return }
        autoremoveTask = Task { await performAutoremove() }
    }

    func cancelRemoveUnusedDependencies() {
        autoremoveTask?.cancel()
        autoremoveTask = nil
    }

    // MARK: - Background updates (called by StatusChecker)

    /// Any foreground action already holds the truth for the state StatusChecker's
    /// background callbacks would otherwise overwrite — e.g. a manual refresh can
    /// finish and reset `isRefreshing` before a concurrent background check's
    /// callbacks land, since the two run on independent, unsynchronized timers.
    /// Without this guard, `updatePackages`/`updateServices`/`updateDoctorWarnings`
    /// would clobber whatever the foreground action just fetched with the background
    /// check's (possibly older) snapshot.
    private var isBusyWithForegroundAction: Bool {
        isUpgrading || isRefreshing || isCleaningUp || isRemovingUnusedDependencies
    }

    func updatePackages(_ packages: [OutdatedPackage]) {
        guard !isBusyWithForegroundAction else { return }
        outdatedPackages = packages
        lastChecked = Date()
        recomputeStatus()
        Task { await refreshInsights() }
    }

    func updateServices(_ entries: [ServiceEntry]) {
        guard !isBusyWithForegroundAction else { return }
        services = entries
    }

    func startService(_ name: String) {
        guard !togglingServices.contains(name) else { return }
        togglingServices.insert(name)
        Task {
            defer { togglingServices.remove(name) }
            do {
                try await service.startService(name)
                let updated = try await service.fetchServices()
                services = updated
            } catch {
                // Per SPECT: show error message, don't escalate privileges.
                status = .error(message(from: error))
            }
        }
    }

    func stopService(_ name: String) {
        guard !togglingServices.contains(name) else { return }
        togglingServices.insert(name)
        Task {
            defer { togglingServices.remove(name) }
            do {
                try await service.stopService(name)
                let updated = try await service.fetchServices()
                services = updated
            } catch {
                status = .error(message(from: error))
            }
        }
    }

    func updateDoctorWarnings(_ warnings: [DoctorWarning]) {
        guard !isBusyWithForegroundAction else { return }
        doctorWarnings = warnings
        recomputeStatus()
        Task { await notifier?.notifyNewDoctorWarnings(warnings) }
    }

    func handleBackgroundError(_ error: Error) {
        guard !isBusyWithForegroundAction else { return }
        status = .error(message(from: error))
    }

    // MARK: - Internal async (exposed for testing)

    func performBootstrap(customBrewPath: String? = nil) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await service.bootstrap(customBrewPath: customBrewPath)
            try await fetchAndUpdateState()
        } catch let e as BrewError {
            if case .notFound = e {
                status = .error(L("Homebrew not found. Set the path in Settings."))
            } else {
                status = .error(message(from: e))
            }
        } catch {
            status = .error(message(from: error))
        }
    }

    func performUpgradeAll() async {
        let countBeforeUpgrade = outdatedPackages.count
        upgradeLog = []
        isUpgrading = true
        defer {
            isUpgrading = false
            upgradeTask = nil
        }
        do {
            let hadBrewMenuUpdate = outdatedPackages.contains { $0.name == "brewmenu" && $0.isCask }
            try await service.runUpgradeAll { [weak self] line in
                Task { @MainActor [weak self] in self?.upgradeLog.append(line) }
            }
            await notifier?.resetAfterUpgrade()
            try await fetchAndUpdateState()
            await notifier?.notifyUpgradeCompleted(count: countBeforeUpgrade)
            if hadBrewMenuUpdate { needsRestart = true }
        } catch is CancellationError {
            recomputeStatus()
        } catch {
            status = .error(message(from: error))
            let reason = message(from: error)
            if countBeforeUpgrade > 0 {
                await notifier?.notifyUpgradeFailed(reason: reason)
            }
        }
    }

    func performCleanUp() async {
        cleanupLog = []
        isCleaningUp = true
        defer {
            isCleaningUp = false
            cleanupTask = nil
        }
        do {
            try await service.runCleanup { [weak self] line in
                Task { @MainActor [weak self] in self?.cleanupLog.append(line) }
            }
            // Records a fresh snapshot with the post-cleanup byte count so the
            // "Cleanup pending" insight clears immediately — without this it would
            // keep citing the pre-cleanup number until StatusChecker's next
            // scheduled run (up to 24h later), even though the space is already back.
            await recordHygieneSnapshot()
            try await fetchAndUpdateState()
        } catch is CancellationError {
            recomputeStatus()
        } catch {
            status = .error(message(from: error))
        }
    }

    func performAutoremove() async {
        autoremoveLog = []
        isRemovingUnusedDependencies = true
        defer {
            isRemovingUnusedDependencies = false
            autoremoveTask = nil
        }
        do {
            try await service.runAutoremove { [weak self] line in
                Task { @MainActor [weak self] in self?.autoremoveLog.append(line) }
            }
            // Same reasoning as performCleanUp: record the post-removal state right
            // away instead of waiting on StatusChecker's next scheduled run so the
            // "Unused dependencies" insight clears immediately.
            await recordHygieneSnapshot()
            try await fetchAndUpdateState()
        } catch is CancellationError {
            recomputeStatus()
        } catch {
            status = .error(message(from: error))
        }
    }

    // MARK: - Private

    /// Refreshes both cleanup-bytes and autoremovable-formulae and records a fresh
    /// snapshot — shared by `performCleanUp` and `performAutoremove` since either
    /// action can affect what the other would report (uninstalling a dependency can
    /// free space; a big cleanup doesn't touch autoremove candidates, but re-checking
    /// both keeps the recorded snapshot accurate regardless of which action ran it).
    private func recordHygieneSnapshot() async {
        guard let historyStore else { return }
        let bytes = (try? await service.runCleanupDryRun()) ?? 0
        let autoremovable = (try? await service.runAutoremoveDryRun()) ?? []
        let casks = (try? await service.fetchInstalledCasks()) ?? []
        let snapshot = Snapshot(
            outdatedPackages: outdatedPackages,
            doctorWarnings: doctorWarnings,
            services: services,
            installedCasks: casks,
            cleanupBytesReclaimable: bytes,
            autoremovableFormulae: autoremovable
        )
        try? await historyStore.save(snapshot)
    }

    private func fetchAndUpdateState() async throws {
        let packages = try await service.fetchOutdated()
        let fetchedServices = try await service.fetchServices()
        // Load snapshots before touching any @Observable state. This ensures that the
        // window-resize layout pass (spinner → package list) and the isRefreshing=false
        // update are batched into a single SwiftUI render, preventing the AppKit
        // "layoutSubtreeIfNeeded called during layout" recursion that empties the content area.
        let snapshots = await recentSnapshots()
        outdatedPackages = packages
        services = fetchedServices
        lastChecked = Date()
        recomputeStatus()
        // `snapshots` only reflects StatusChecker's last scheduled save (up to an hour
        // behind) — folding in what was just fetched here as the newest entry keeps an
        // insight like "N packages accumulated" from citing a stale, larger count right
        // after a manual refresh or upgrade already brought the live count down.
        let current = Snapshot(
            outdatedPackages: packages,
            doctorWarnings: doctorWarnings,
            services: fetchedServices,
            installedCasks: snapshots.first?.installedCasks ?? [],
            cleanupBytesReclaimable: snapshots.first?.cleanupBytesReclaimable ?? 0,
            autoremovableFormulae: snapshots.first?.autoremovableFormulae ?? []
        )
        let newInsights = InsightEngine.insights(from: [current] + snapshots)
        insights = newInsights
        autoremovableFormulae = snapshots.first?.autoremovableFormulae ?? []
        // Captured as a local, not read back off `self.insights` inside the Task: a
        // concurrent `refreshInsights()` (spawned by a racing background `updatePackages`)
        // could overwrite `insights` before this Task runs, which would notify about the
        // wrong insight list and desync `BrewNotifier`'s dedup baseline.
        Task { await notifier?.notifyNewCriticalInsights(newInsights) }
    }

    // Background StatusChecker updates: recompute insights after packages change.
    private func refreshInsights() async {
        let snapshots = await recentSnapshots()
        let newInsights = InsightEngine.insights(from: snapshots)
        insights = newInsights
        autoremovableFormulae = snapshots.first?.autoremovableFormulae ?? []
        Task { await notifier?.notifyNewCriticalInsights(newInsights) }
    }

    private func recentSnapshots() async -> [Snapshot] {
        guard let historyStore else { return [] }
        return (try? await historyStore.loadRecent()) ?? []
    }

    /// Derives status from current warnings + packages. Priority: error > warning > updates > ok.
    private func recomputeStatus() {
        if doctorWarnings.contains(where: { $0.severity == .error }) {
            status = .error(L("Doctor found errors. Run `brew doctor` in Terminal."))
            return
        }
        if !doctorWarnings.isEmpty {
            status = .warning(count: doctorWarnings.count)
            return
        }
        status = outdatedPackages.isEmpty ? .ok : .updates(count: outdatedPackages.count)
    }

    private func message(from error: Error) -> String {
        error.localizedDescription
    }
}
