import Foundation

@MainActor
@Observable
final class MenuBarViewModel {
    @ObservationIgnored private let service: any BrewServicing
    @ObservationIgnored private let notifier: BrewNotifier?
    @ObservationIgnored private let historyStore: HistoryStore?
    @ObservationIgnored private var upgradeTask: Task<Void, Never>?

    private(set) var status: MenuBarStatus = .initializing
    private(set) var outdatedPackages: [OutdatedPackage] = []
    private(set) var doctorWarnings: [DoctorWarning] = []
    private(set) var insights: [Insight] = []
    private(set) var services: [ServiceEntry] = []
    private(set) var upgradeLog: [String] = []
    private(set) var isRefreshing: Bool = false
    private(set) var isUpgrading: Bool = false
    private(set) var lastChecked: Date? = nil
    private(set) var togglingServices: Set<String> = []
    private(set) var upgradingPackages: Set<String> = []
    private(set) var needsRestart: Bool = false

    /// Services with a meaningful status (excludes "inactive" / "unknown" since they have no action).
    var visibleServices: [ServiceEntry] {
        services.filter { $0.status == .started || $0.status == .stopped || $0.status == .error }
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

    // MARK: - Background updates (called by StatusChecker)

    func updatePackages(_ packages: [OutdatedPackage]) {
        guard !isUpgrading else { return }
        outdatedPackages = packages
        lastChecked = Date()
        recomputeStatus()
        Task { await refreshInsights() }
    }

    func updateServices(_ entries: [ServiceEntry]) {
        guard !isUpgrading else { return }
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
        guard !isUpgrading else { return }
        doctorWarnings = warnings
        recomputeStatus()
        Task { await notifier?.notifyNewDoctorWarnings(warnings) }
    }

    func handleBackgroundError(_ error: Error) {
        guard !isUpgrading, !isRefreshing else { return }
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

    // MARK: - Private

    private func fetchAndUpdateState() async throws {
        let packages = try await service.fetchOutdated()
        // Load snapshots before touching any @Observable state. This ensures that the
        // window-resize layout pass (spinner → package list) and the isRefreshing=false
        // update are batched into a single SwiftUI render, preventing the AppKit
        // "layoutSubtreeIfNeeded called during layout" recursion that empties the content area.
        let snapshots = await recentSnapshots()
        outdatedPackages = packages
        lastChecked = Date()
        recomputeStatus()
        insights = InsightEngine.insights(from: snapshots)
        Task { await notifier?.notifyNewCriticalInsights(insights) }
    }

    // Background StatusChecker updates: recompute insights after packages change.
    private func refreshInsights() async {
        let snapshots = await recentSnapshots()
        let newInsights = InsightEngine.insights(from: snapshots)
        insights = newInsights
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
        guard let e = error as? BrewError else { return error.localizedDescription }
        switch e {
        case .notFound:
            return L("Homebrew not found.")
        case .notConfigured:
            return L("Service not configured.")
        case .commandFailed(let code, let stderr):
            return L("Command failed (code \(code)): \(stderr)")
        case .outputParsingFailed(let cmd):
            return L("Could not parse output of '\(cmd)'.")
        }
    }
}
