import Foundation

actor StatusChecker {

    enum Interval: Sendable {
        case hourly     // fetchOutdated cada 1h, runUpdate cada 6h
        case sixHours   // runUpdate + fetchOutdated cada 6h
        case daily      // runUpdate + fetchOutdated cada 24h
        case manual     // sin chequeos automáticos

        var seconds: Double? {
            switch self {
            case .hourly: 3600
            case .sixHours: 21600
            case .daily: 86400
            case .manual: nil
            }
        }

        // Cuántos chequeos por ciclo de update
        var checksPerUpdate: Int {
            switch self {
            case .hourly: 6   // update cada 6 chequeos = cada 6h
            case .sixHours, .daily, .manual: 1
            }
        }
    }

    private static let doctorInterval: TimeInterval = 86400        // 24h
    private static let caskInventoryInterval: TimeInterval = 21600  // 6h

    private let service: any BrewServicing
    private let historyStore: HistoryStore?
    private let onPackagesUpdated: @Sendable ([OutdatedPackage]) -> Void
    private let onDoctorCompleted: @Sendable ([DoctorWarning]) -> Void
    private let onServicesUpdated: @Sendable ([ServiceEntry]) -> Void
    private let onError: @Sendable (Error) -> Void

    private var interval: Interval
    private var timerTask: Task<Void, Never>?
    private var checkCount: Int = 0
    private var lastDoctorRunAt: Date? = nil
    private var lastCaskInventoryAt: Date? = nil
    private var latestWarnings: [DoctorWarning] = []
    private var latestServices: [ServiceEntry] = []
    private var latestInstalledCasks: [CaskEntry] = []
    private var latestCleanupBytes: Int64 = 0

    init(
        service: any BrewServicing,
        historyStore: HistoryStore? = nil,
        interval: Interval = .hourly,
        onPackagesUpdated: @escaping @Sendable ([OutdatedPackage]) -> Void,
        onDoctorCompleted: @escaping @Sendable ([DoctorWarning]) -> Void = { _ in },
        onServicesUpdated: @escaping @Sendable ([ServiceEntry]) -> Void = { _ in },
        onError: @escaping @Sendable (Error) -> Void
    ) {
        self.service = service
        self.historyStore = historyStore
        self.interval = interval
        self.onPackagesUpdated = onPackagesUpdated
        self.onDoctorCompleted = onDoctorCompleted
        self.onServicesUpdated = onServicesUpdated
        self.onError = onError
    }

    // MARK: - Public API

    func start() {
        scheduleTimer()
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    func checkNow() {
        Task { await self.performCheck() }
    }

    func setInterval(_ newInterval: Interval) {
        let wasRunning = timerTask != nil
        interval = newInterval
        stop()
        if wasRunning { scheduleTimer() }
    }

    // MARK: - Internal (exposed for testing)

    func performCheck() async {
        checkCount += 1
        let shouldUpdate = checkCount % interval.checksPerUpdate == 0
        let shouldRunDoctor = lastDoctorRunAt.map {
            Date().timeIntervalSince($0) >= Self.doctorInterval
        } ?? true
        let shouldRunCaskInventory = lastCaskInventoryAt.map {
            Date().timeIntervalSince($0) >= Self.caskInventoryInterval
        } ?? true

        do {
            if shouldRunDoctor {
                lastDoctorRunAt = Date()
                let warnings = try await service.runDoctor()
                latestWarnings = warnings
                onDoctorCompleted(warnings)
                // Cleanup dry-run runs at the same cadence as doctor (every 24h). Non-fatal.
                latestCleanupBytes = (try? await service.runCleanupDryRun()) ?? latestCleanupBytes
            }
            if shouldRunCaskInventory {
                lastCaskInventoryAt = Date()
                // Non-fatal: systems without casks return empty output rather than an error.
                latestInstalledCasks = (try? await service.fetchInstalledCasks()) ?? latestInstalledCasks
            }
            if shouldUpdate { try await service.runUpdate() }
            let packages = try await service.fetchOutdated()
            onPackagesUpdated(packages)
            // Services are non-fatal: ignore failures so a brew services issue doesn't kill the check.
            let services = (try? await service.fetchServices()) ?? latestServices
            latestServices = services
            onServicesUpdated(services)
            saveSnapshot(packages: packages, warnings: latestWarnings, services: latestServices, installedCasks: latestInstalledCasks, cleanupBytes: latestCleanupBytes)
        } catch {
            onError(error)
        }
    }

    // MARK: - Private

    private func saveSnapshot(packages: [OutdatedPackage], warnings: [DoctorWarning], services: [ServiceEntry], installedCasks: [CaskEntry], cleanupBytes: Int64) {
        guard let historyStore else { return }
        let snapshot = Snapshot(outdatedPackages: packages, doctorWarnings: warnings, services: services, installedCasks: installedCasks, cleanupBytesReclaimable: cleanupBytes)
        Task {
            try? await historyStore.save(snapshot)
        }
    }

    private func scheduleTimer() {
        guard let seconds = interval.seconds else { return }
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { break }
                await self.performCheck()
            }
        }
    }
}
