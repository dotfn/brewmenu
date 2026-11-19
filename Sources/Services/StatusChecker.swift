import BrewCore
import Foundation

/// The timer behind the automatic checks: decides when to run `brew update`, `brew doctor` and the
/// cask inventory, and has `BrewStore` do the fetching. It keeps no brew state of its own — that
/// lived here too once, and drifted from what the menu bar showed.
actor StatusChecker {
    enum Interval {
        case hourly // fetchOutdated every 1h, runUpdate every 6h
        case sixHours // runUpdate + fetchOutdated every 6h
        case daily // runUpdate + fetchOutdated every 24h
        case manual // no automatic checks

        var seconds: Double? {
            switch self {
            case .hourly: 3600
            case .sixHours: 21600
            case .daily: 86400
            case .manual: nil
            }
        }

        /// How many checks happen per update cycle
        var checksPerUpdate: Int {
            switch self {
            case .hourly: 6 // one update every 6 checks = every 6h
            case .sixHours, .daily, .manual: 1
            }
        }
    }

    private static let doctorInterval: TimeInterval = 86400 // 24h
    private static let caskInventoryInterval: TimeInterval = 21600 // 6h
    private static let servicesPollingInterval: TimeInterval = 30 // 30s

    private let store: BrewStore
    private let logger: BrewLogger

    private var interval: Interval
    private var timerTask: Task<Void, Never>?
    private var servicesTimerTask: Task<Void, Never>?
    private var checkCount: Int = 0
    private var lastDoctorRunAt: Date?
    private var lastCaskInventoryAt: Date?

    init(store: BrewStore, interval: Interval = .hourly, logger: BrewLogger = .shared) {
        self.store = store
        self.interval = interval
        self.logger = logger
    }

    // MARK: - Public API

    func start() {
        guard timerTask == nil else { return }
        scheduleTimer()
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        servicesTimerTask?.cancel()
        servicesTimerTask = nil
    }

    func setInterval(_ newInterval: Interval) {
        let wasRunning = timerTask != nil
        interval = newInterval
        timerTask?.cancel()
        timerTask = nil
        if wasRunning { scheduleTimer() }
    }

    /// Only polls services while the popover is visible, since `brew services list`
    /// spawns a full brew process — running it every 30s in the background regardless
    /// of whether anyone is looking drains battery for no benefit.
    func startServicesPolling() {
        guard servicesTimerTask == nil else { return }
        Task { await self.refreshServicesOnce() }
        scheduleServicesTimer()
    }

    func stopServicesPolling() {
        servicesTimerTask?.cancel()
        servicesTimerTask = nil
    }

    // MARK: - Internal (exposed for testing)

    func performCheck() async {
        await logger.log("StatusChecker: check #\(checkCount + 1) started")
        checkCount += 1
        let shouldUpdate = checkCount % interval.checksPerUpdate == 0
        let shouldRunDoctor = lastDoctorRunAt.map {
            Date().timeIntervalSince($0) >= Self.doctorInterval
        } ?? true
        let shouldRunCaskInventory = lastCaskInventoryAt.map {
            Date().timeIntervalSince($0) >= Self.caskInventoryInterval
        } ?? true

        // Stamped when they're asked for, not when they succeed: a failing `brew doctor` isn't
        // retried on every check.
        if shouldRunDoctor { lastDoctorRunAt = Date() }
        if shouldRunCaskInventory { lastCaskInventoryAt = Date() }
        // The cleanup/autoremove dry-runs run on every check, not gated behind the 24h doctor
        // interval: that gate left the "Unused dependencies"/"Cleanup pending" insights stale for
        // most of a day. Both are read-only and cheap.
        await store.runScheduledCheck(BrewStore.CheckPlan(
            runUpdate: shouldUpdate,
            runDoctor: shouldRunDoctor,
            refreshCasks: shouldRunCaskInventory
        ))
    }

    // MARK: - Private

    /// The shared loop shape behind both timers below: sleep, then run `action`,
    /// until cancelled. Extracted after the two timers drifted into near-identical,
    /// hand-duplicated copies of this exact loop — which is how the services timer
    /// went a full release without the visibility-gating the main timer already had.
    private func makeLoopTask(seconds: TimeInterval,
                              action: @escaping @Sendable () async -> Void) -> Task<Void, Never>
    {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { break }
                await action()
            }
        }
    }

    private func scheduleTimer() {
        guard let seconds = interval.seconds else { return }
        timerTask = makeLoopTask(seconds: seconds) { [weak self] in
            await self?.performCheck()
        }
    }

    private func scheduleServicesTimer() {
        servicesTimerTask = makeLoopTask(seconds: Self.servicesPollingInterval) { [weak self] in
            await self?.refreshServicesOnce()
        }
    }

    private func refreshServicesOnce() async {
        await store.refresh([.services])
    }
}
