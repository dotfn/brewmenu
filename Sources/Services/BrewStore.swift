import BrewCore
import Foundation

/// The one copy of what Homebrew reports: installed and outdated packages, taps, services,
/// `brew doctor`, the cleanup/autoremove dry-runs, and the insights built from them. The menu bar,
/// the Dashboard and `StatusChecker` all read and refresh this instead of keeping their own lists,
/// which used to drift apart (an upgrade from the menu bar left the Dashboard's installed list on
/// the old version; an uninstall from the Dashboard left the package in the menu's outdated list).
///
/// Two rules keep it consistent:
/// - **Newest question wins.** Every result is stamped with when it was asked for, and one that
///   was asked before the result already shown is dropped. A slow background check can't
///   overwrite what a later foreground refresh found.
/// - **A change says what it touched.** After a mutating brew command, callers ask for
///   `refresh(after:)`, and `scopes(after:)` is the one place that knows which data each kind of
///   command can change.
@MainActor
@Observable
final class BrewStore {
    /// One piece of brew state, fetched by its own command. Declared in the order a refresh asks
    /// for them.
    enum Scope: CaseIterable {
        case doctor, casks, outdated, cleanup, autoremove, services, installed, taps
    }

    /// What a scheduled check covers on top of the outdated list, the dry-runs and services.
    struct CheckPlan: Equatable {
        var runUpdate = false
        var runDoctor = false
        var refreshCasks = false
    }

    private(set) var outdated: [OutdatedPackage] = [] {
        didSet { outdatedNames = Set(outdated.flatMap { [$0.name, Self.bareName($0.name)] }) }
    }

    /// Both names of every outdated package (see `bareName`), rebuilt with `outdated` — rows ask
    /// on every render.
    private var outdatedNames: Set<String> = []
    /// When `outdated` was asked of brew — nil until the first check.
    private(set) var lastChecked: Date?
    private(set) var installed: [InstalledPackage] = [] {
        didSet {
            installedByName = Dictionary(installed.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            installedByTap = Dictionary(grouping: installed, by: \.tap)
        }
    }

    /// Name- and tap-keyed mirrors of `installed`, rebuilt with it. Rows ask for these on every
    /// render, and a scan of the whole list per row was too slow.
    private(set) var installedByName: [String: InstalledPackage] = [:]
    private(set) var installedByTap: [String: [InstalledPackage]] = [:]
    private(set) var taps: [Tap] = []
    private(set) var services: [ServiceEntry] = []
    private(set) var doctorWarnings: [DoctorWarning] = []
    /// When the `brew doctor` result shown was asked for — nil until it first runs, so "no
    /// warnings" can't be shown for a check that never happened.
    private(set) var doctorCheckedAt: Date?
    /// Titles of the findings the user ignored (`AppSettings.ignoredDoctorWarnings`, kept in step
    /// by `SettingsViewModel.bindIgnoredDoctorWarnings`). By title, not the whole message: a
    /// finding's list of tools or packages changes from run to run, and ignoring it shouldn't undo
    /// itself when it does.
    private(set) var ignoredDoctorTitles: Set<String> = []

    func setIgnoredDoctorTitles(_ titles: Set<String>) {
        ignoredDoctorTitles = titles
    }

    /// The findings the icon, the popover and notifications count.
    var visibleDoctorWarnings: [DoctorWarning] {
        doctorWarnings.filter { !ignoredDoctorTitles.contains($0.title) }
    }

    var ignoredDoctorWarnings: [DoctorWarning] {
        doctorWarnings.filter { ignoredDoctorTitles.contains($0.title) }
    }

    private(set) var installedCasks: [CaskEntry] = []
    private(set) var cleanupBytesReclaimable: Int64 = 0
    private(set) var autoremovableFormulae: [String] = []
    private(set) var insights: [Insight] = []
    /// Why the last fetch of each scope failed, cleared by its next success. Screens show this
    /// instead of an empty list that would read as a real result.
    private(set) var failures: [Scope: String] = [:]
    /// The error the menu bar shows. Set by a failed scheduled check or by an action that failed
    /// (`report`), and cleared by the next good outdated list or `brew doctor` run.
    private(set) var lastError: String?
    /// Fetches in flight per scope, whoever asked for them — see `isRefreshing(_:)`.
    private var inFlight: [Scope: Int] = [:]
    /// Update checks in flight (`brew update` plus the outdated list), whoever started them: the
    /// menu bar's Refresh, the Dashboard's, or the timer. Each screen used to have its own flag,
    /// and neither showed a check the other one (or the timer) had started.
    private var updateChecks = 0

    var isCheckingForUpdates: Bool {
        updateChecks > 0
    }

    /// Homebrew's full catalog (see `PackageCatalog`), loaded when something first asks for it —
    /// the Dashboard does; the menu bar never needs it.
    private(set) var catalog: PackageCatalogIndex? {
        didSet { catalogVersion += 1 }
    }

    /// Bumped whenever `catalog` is replaced — what lists derived from it are keyed on, since a
    /// new catalog can have exactly as many packages as the old one.
    private(set) var catalogVersion = 0
    private(set) var isLoadingCatalog = false
    /// Why the last catalog download failed. What's on screen stays: an older catalog is still
    /// right about nearly everything.
    private(set) var catalogError: String?
    /// When the package database was last brought up to date — by a `brew update` from here, or by
    /// Homebrew itself (a `brew update` in Terminal counts too). Nil until first asked.
    private(set) var databaseSyncedAt: Date?

    /// How old the package database may get before an install or upgrade brings it up to date
    /// first. Homebrew does the same before `brew install`, but this app turns that off for every
    /// command (`HOMEBREW_NO_AUTO_UPDATE`, see `BrewService`) because it can hang a plain status
    /// read; doing it here, visibly, keeps the "install from a fresh database" part.
    static let databaseMaxAge: TimeInterval = 15 * 60
    /// How old the downloaded catalog may get before opening the Dashboard downloads it again.
    static let catalogMaxAge: TimeInterval = 24 * 60 * 60

    @ObservationIgnored private let service: any BrewServicing
    @ObservationIgnored private let historyStore: HistoryStore?
    @ObservationIgnored private let notifier: BrewNotifier?
    @ObservationIgnored private let installedCache: InstalledPackagesCache?
    @ObservationIgnored private let packageCatalog: (any PackageCatalogServicing)?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    /// When the running catalog download started — one that started before a `brew update`
    /// finished may predate it, so the update asks for another (see `refreshCatalog(after:)`).
    @ObservationIgnored private var catalogTaskStartedAt = Date.distantPast
    @ObservationIgnored private var catalogReadTask: Task<Void, Never>?
    /// The `brew update` running now, if any — a second caller waits for it instead of running
    /// another one right behind it.
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private let logger: BrewLogger
    /// When the result on screen for each scope was asked for — see "newest question wins".
    @ObservationIgnored private var appliedAt: [Scope: Date] = [:]
    /// Scopes that hold something real (fetched, or painted from a cache).
    @ObservationIgnored private var loaded: Set<Scope> = []

    /// The snapshot this store saved last. Insights read the live state as the newest check, and
    /// when the newest snapshot is one this store saved, the live state *is* that check, moved on —
    /// so it takes its place instead of sitting on top of it. Counting it twice hid every change
    /// between the last two checks (a service that stopped) as soon as anything was refetched.
    @ObservationIgnored private var lastSavedSnapshotID: UUID?
    @ObservationIgnored private var restoredFromHistory = false

    init(
        service: any BrewServicing,
        historyStore: HistoryStore? = nil,
        notifier: BrewNotifier? = nil,
        installedCache: InstalledPackagesCache? = nil,
        packageCatalog: (any PackageCatalogServicing)? = nil,
        logger: BrewLogger = .shared
    ) {
        self.service = service
        self.historyStore = historyStore
        self.notifier = notifier
        self.installedCache = installedCache
        self.packageCatalog = packageCatalog
        self.logger = logger
    }

    /// What each kind of brew command can change. Installed packages are refetched even with the
    /// Dashboard closed, so its on-disk cache doesn't paint a stale list the next time it opens.
    static func scopes(after kind: BrewOperations.Kind) -> Set<Scope> {
        switch kind {
        case .update: [.outdated]
        // An upgrade or install can bring dependencies along, so the outdated list changes too.
        // An upgrade can also leave one behind that nothing needs any more (postgresql@18 moving
        // to icu4c@79 left icu4c@78), which the autoremove dry-run is what finds.
        case .upgrade: [.outdated, .installed, .casks, .autoremove]
        case .install: [.outdated, .installed, .casks]
        case .uninstall: [.outdated, .installed, .casks, .autoremove]
        case .tap, .untap: [.taps]
        // Either one can change what the other would report, so both dry-runs are redone.
        case .cleanup: [.cleanup, .autoremove, .casks, .outdated, .services]
        case .autoremove: [.cleanup, .autoremove, .casks, .outdated, .services, .installed]
        }
    }

    // MARK: - Refreshing

    /// Fetches `scopes` and returns what failed, keyed by scope. A failed scope keeps what it had.
    /// `recordSnapshot` saves the result to history (cleanup, autoremove).
    @discardableResult
    func refresh(_ scopes: Set<Scope>, recordSnapshot: Bool = false) async -> [Scope: Error] {
        await perform(scopes) { _ in recordSnapshot }
    }

    /// The refresh a finished brew command calls for (see `scopes(after:)`).
    @discardableResult
    func refresh(after kind: BrewOperations.Kind, recordSnapshot: Bool = false) async -> [Scope: Error] {
        await refresh(Self.scopes(after: kind), recordSnapshot: recordSnapshot)
    }

    /// `brew update`, then the outdated list. A failed update isn't fatal: the local index is
    /// still usable, and the list below is still right for it.
    @discardableResult
    func checkForUpdates() async -> [Scope: Error] {
        updateChecks += 1
        defer { updateChecks -= 1 }
        await runUpdate()
        return await refresh([.outdated, .services])
    }

    /// What `StatusChecker` runs on its timer. Saves a snapshot unless the check itself failed, and
    /// notifies about what's new.
    func runScheduledCheck(_ plan: CheckPlan) async {
        updateChecks += 1
        defer { updateChecks -= 1 }
        if plan.runUpdate { await runUpdate() }
        var scopes: Set<Scope> = [.outdated, .cleanup, .autoremove, .services]
        if plan.runDoctor { scopes.insert(.doctor) }
        if plan.refreshCasks { scopes.insert(.casks) }
        // Only the outdated list and doctor make a check fail; the rest keep their last value. A
        // cancelled check (the interval changed, the app is quitting) records and reports nothing.
        let errors = await perform(scopes) { errors in
            errors[.outdated] == nil && errors[.doctor] == nil && !Task.isCancelled
        }
        guard !Task.isCancelled else { return }
        if let fatal = errors[.outdated] ?? errors[.doctor] {
            lastError = fatal.localizedDescription
        }
        if errors[.outdated] == nil {
            await notifier?.notifyIfUpdatesIncreased(to: outdated.count)
        }
        if errors[.doctor] == nil, plan.runDoctor {
            await notifier?.notifyNewDoctorWarnings(doctorWarnings, ignoring: ignoredDoctorTitles)
        }
    }

    /// `brew doctor` on its own, at launch and from the Doctor page's Check Again. The scheduled
    /// check runs it once a day, starting an hour after launch: a problem the user had just fixed
    /// stayed listed for up to a day, and with "Manual" checks doctor never ran at all. Announces
    /// nothing — someone asked, or the app just started — but notes what it found as seen, so the
    /// next scheduled check doesn't announce it as new.
    func runDoctor() async {
        // The launch run and a Check Again clicked during it would otherwise be two `brew doctor`s.
        guard !isRefreshing(.doctor) else { return }
        let errors = await refresh([.doctor])
        if errors[.doctor] == nil { await notifier?.noteDoctorWarnings(doctorWarnings) }
    }

    // MARK: - Package database

    /// Brings the package database up to date when it's older than `databaseMaxAge`, the way
    /// pacman front-ends sync before a transaction. `willSync` runs first, so the caller can say
    /// so in its log. Returns whether a sync ran.
    @discardableResult
    func syncDatabaseIfStale(willSync: () -> Void = {}) async -> Bool {
        if databaseSyncedAt == nil { await noteDatabaseFetched(service.databaseFetchedAt()) }
        // Checked after the await above: a sync that finished meanwhile counts.
        if let syncedAt = databaseSyncedAt, Date().timeIntervalSince(syncedAt) < Self.databaseMaxAge {
            return false
        }
        willSync()
        updateChecks += 1
        defer { updateChecks -= 1 }
        await runUpdate()
        return true
    }

    /// Shows the catalog from disk right away, then downloads a new one if it's missing, older than
    /// `catalogMaxAge`, or older than the last `brew update`.
    func loadCatalog() async {
        guard let packageCatalog else { return }
        if catalog == nil { await readCatalogFromDisk() }
        if databaseSyncedAt == nil { await noteDatabaseFetched(service.databaseFetchedAt()) }
        let downloadedAt = await packageCatalog.downloadedAt()
        let isStale = downloadedAt.map { downloaded in
            Date().timeIntervalSince(downloaded) > Self.catalogMaxAge
                || databaseSyncedAt.map { $0 > downloaded } == true
        } ?? true
        if catalog == nil || isStale { await refreshCatalog() }
    }

    /// One download at a time: a second caller waits for the one already running — unless that
    /// one started before `after`, in which case another follows it.
    func refreshCatalog(after: Date = .distantPast) async {
        if let catalogTask {
            await catalogTask.value
            if catalogTaskStartedAt >= after { return }
            if let newer = self.catalogTask, newer != catalogTask {
                await newer.value
                return
            }
        }
        let task = Task { await downloadCatalog() }
        catalogTask = task
        catalogTaskStartedAt = Date()
        await task.value
        if catalogTask == task { catalogTask = nil }
    }

    /// One read at a time: decoding both files twice (two Dashboard loads) is ~50 MB of work.
    private func readCatalogFromDisk() async {
        if let catalogReadTask {
            await catalogReadTask.value
            return
        }
        let task = Task {
            guard let packageCatalog, catalog == nil else { return }
            do {
                let cached = try await packageCatalog.cached()
                if catalog == nil { catalog = cached }
            } catch {
                await logger.log("BrewStore: reading the catalog failed — \(error.localizedDescription)", .error)
            }
        }
        catalogReadTask = task
        await task.value
        catalogReadTask = nil
    }

    /// Homebrew's own fetch date only ever moves the database's date forward: one read from disk
    /// mustn't undo a `brew update` that finished while it was being read.
    private func noteDatabaseFetched(_ date: Date?) {
        guard let date else { return }
        databaseSyncedAt = max(databaseSyncedAt ?? .distantPast, date)
    }

    func catalogPackage(named name: String, isCask: Bool) -> CatalogPackage? {
        catalog?.package(named: name, isCask: isCask)
    }

    private func downloadCatalog() async {
        guard let packageCatalog else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            if let fresh = try await packageCatalog.refresh() { catalog = fresh }
            catalogError = nil
        } catch {
            catalogError = error.localizedDescription
            await logger.log("BrewStore: downloading the catalog failed — \(error.localizedDescription)", .error)
        }
    }

    // MARK: - Applying results

    /// Applies an outdated list asked for at `startedAt` — dropped if a later one is already shown.
    @discardableResult
    func applyOutdated(_ packages: [OutdatedPackage], startedAt: Date = .now) -> Bool {
        guard accept(.outdated, startedAt: startedAt) else { return false }
        outdated = packages
        lastChecked = startedAt
        lastError = nil
        return true
    }

    /// Records an action's failure for the menu bar (see `lastError`).
    func report(_ message: String) {
        lastError = message
    }

    /// Takes an action's failure back once a retry of it worked — unless something else has been
    /// reported since. Otherwise the icon stayed red until the next update check.
    func withdraw(_ message: String) {
        if lastError == message { lastError = nil }
    }

    /// Paints the installed list from the on-disk cache when nothing is loaded yet, so a launch
    /// doesn't wait on `brew info`. Returns whether there's anything to show. A real fetch always
    /// replaces it: the cache is stamped as asked-for at the distant past.
    func primeInstalledFromCache() async -> Bool {
        guard installed.isEmpty else { return true }
        guard let installedCache else { return false }
        let cached = await installedCache.installedPackages
        guard !cached.isEmpty, installed.isEmpty else { return !installed.isEmpty }
        installed = cached
        taps = await installedCache.taps
        loaded.formUnion([.installed, .taps])
        return true
    }

    /// Fills in the dry-run results and cask list from the newest snapshot, until the first
    /// scheduled check measures them again. Without it, the insights built from them (cleanup
    /// pending, unused dependencies) went missing for the first hour after every launch.
    func restoreFromHistory() async {
        guard !restoredFromHistory else { return }
        restoredFromHistory = true
        guard let latest = await recentSnapshots().first else { return }
        if !loaded.contains(.casks) { installedCasks = latest.installedCasks }
        if !loaded.contains(.cleanup) { cleanupBytesReclaimable = latest.cleanupBytesReclaimable }
        if !loaded.contains(.autoremove) { autoremovableFormulae = latest.autoremovableFormulae }
    }

    // MARK: - Lookups

    /// Whether some fetch of `scope` is running — for spinners, whoever started it.
    func isRefreshing(_ scope: Scope) -> Bool {
        inFlight[scope, default: 0] > 0
    }

    /// `brew search` and `brew outdated` name a package from a third-party tap in full
    /// (`user/repo/name`), while the installed list has the bare name.
    static func bareName(_ name: String) -> String {
        String(name.split(separator: "/").last ?? Substring(name))
    }

    func installedPackage(named name: String) -> InstalledPackage? {
        installedByName[name] ?? installedByName[Self.bareName(name)]
    }

    /// Whether `brew outdated` lists the package, under either of its names.
    func isOutdated(_ name: String) -> Bool {
        outdatedNames.contains(name) || outdatedNames.contains(Self.bareName(name))
    }

    // MARK: - Private

    private static let insightScopes: Set<Scope> = [.doctor, .casks, .outdated, .cleanup, .autoremove, .services]

    /// Fetches everything first and applies it all at once, with no suspension in between — so
    /// SwiftUI sees one change, not one per scope. Applying them one by one re-laid out the popover
    /// mid-refresh, which is how AppKit's "layoutSubtreeIfNeeded called during layout" recursion
    /// once emptied its content area.
    private func perform(_ scopes: Set<Scope>, saveSnapshotIf shouldSave: ([Scope: Error]) -> Bool) async
        -> [Scope: Error]
    {
        for scope in scopes {
            inFlight[scope, default: 0] += 1
        }
        var appliers: [(scope: Scope, apply: () -> Bool)] = []
        var errors: [Scope: Error] = [:]
        var startedAt: [Scope: Date] = [:]
        for scope in Scope.allCases where scopes.contains(scope) {
            let started = Date()
            startedAt[scope] = started
            do {
                try await appliers.append((scope, fetch(scope, startedAt: started)))
            } catch is CancellationError {
                // Not a failure: a timer was reset or the popover closed. The scope keeps what it had.
            } catch {
                errors[scope] = error
                await logger.log("BrewStore: \(scope) failed — \(error.localizedDescription)", .error)
            }
        }
        let touchesInsights = !scopes.isDisjoint(with: Self.insightScopes)
        let history = touchesInsights ? await recentSnapshots() : []

        for scope in scopes {
            inFlight[scope, default: 1] -= 1
        }
        let applied = Set(appliers.filter { $0.apply() }.map(\.scope))
        for scope in scopes {
            if applied.contains(scope) {
                failures[scope] = nil
            } else if let error = errors[scope], let started = startedAt[scope],
                      started >= appliedAt[scope, default: .distantPast]
            {
                // Same rule as results: a failure older than what's shown doesn't replace it.
                failures[scope] = error.localizedDescription
            }
        }
        if touchesInsights {
            let earlier = history.first?.id == lastSavedSnapshotID ? Array(history.dropFirst()) : history
            insights = InsightEngine.insights(from: [liveSnapshot] + earlier)
        }

        // Only when the installed list is real: saving after a failed `brew list` wrote an empty
        // list over the cache.
        if !applied.isDisjoint(with: [.installed, .taps]), loaded.contains(.installed) {
            await installedCache?.save(installedPackages: installed, taps: taps)
        }
        if shouldSave(errors) { await saveSnapshot() }
        if touchesInsights { await notifier?.notifyNewCriticalInsights(insights) }
        return errors
    }

    /// The one place `brew update` runs from, one at a time. A good one dates the database and,
    /// once the catalog is in use, downloads it again in the background: both describe what's
    /// available, and should move together.
    ///
    /// A cancelled caller stops waiting right away, but the update is only cancelled once nobody
    /// waits for it any more. Cancelling it for everyone let one caller — a Settings interval
    /// change restarting the timer, a Cancel on an upgrade still syncing — kill the update another
    /// caller had joined, which then carried on as if the database were fresh.
    private func runUpdate() async {
        // Nothing to wait for — and no `brew update` to start only to stop it again.
        guard !Task.isCancelled else { return }
        while true {
            let task = updateTask ?? startUpdateTask()
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { updateWaiters[id] = $0 }
            } onCancel: {
                // Runs once the registration above is done: both are on the main actor, and the
                // registration happens before this caller first suspends.
                Task { @MainActor in self.stopWaitingForUpdate(id) }
            }
            // Joined one that everybody before had left, so it was being stopped: it didn't
            // update anything, and returning now would carry on as if it had. Run another.
            guard task.isCancelled, !Task.isCancelled else { return }
        }
    }

    private func startUpdateTask() -> Task<Void, Never> {
        let task = Task {
            await performUpdate()
            updateTask = nil
            let waiters = updateWaiters
            updateWaiters = [:]
            waiters.values.forEach { $0.resume() }
        }
        updateTask = task
        return task
    }

    /// Callers waiting on the running `brew update` (see `runUpdate`).
    @ObservationIgnored private var updateWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private func stopWaitingForUpdate(_ id: UUID) {
        guard let waiter = updateWaiters.removeValue(forKey: id) else { return }
        waiter.resume()
        if updateWaiters.isEmpty { updateTask?.cancel() }
    }

    private func performUpdate() async {
        do {
            try await service.runUpdate()
            let syncedAt = Date()
            databaseSyncedAt = syncedAt
            if catalog != nil { Task { await refreshCatalog(after: syncedAt) } }
        } catch is CancellationError {
            // Not a failure: whoever asked for it stopped waiting.
        } catch {
            await logger.log("BrewStore: brew update failed — \(error.localizedDescription)", .error)
        }
    }

    /// Runs the scope's brew command and returns what applies its result — which checks, when it
    /// runs, that nothing asked for later has been applied in the meantime.
    private func fetch(_ scope: Scope, startedAt: Date) async throws -> () -> Bool {
        switch scope {
        case .outdated:
            let packages = try await service.fetchOutdated()
            return { self.applyOutdated(packages, startedAt: startedAt) }
        case .installed:
            let packages = try await service.fetchInstalledPackages()
            return applier(scope, startedAt) { $0.installed = packages }
        case .taps:
            let fetched = try await service.fetchTaps()
            return applier(scope, startedAt) { $0.taps = fetched }
        case .services:
            let fetched = try await service.fetchServices()
            return applier(scope, startedAt) { $0.services = fetched }
        case .doctor:
            let warnings = try await service.runDoctor()
            return applier(scope, startedAt) {
                $0.doctorWarnings = warnings
                $0.doctorCheckedAt = startedAt
                $0.lastError = nil
            }
        case .casks:
            let casks = try await service.fetchInstalledCasks()
            return applier(scope, startedAt) { $0.installedCasks = casks }
        case .cleanup:
            let bytes = try await service.runCleanupDryRun()
            return applier(scope, startedAt) { $0.cleanupBytesReclaimable = bytes }
        case .autoremove:
            let formulae = try await service.runAutoremoveDryRun()
            return applier(scope, startedAt) { $0.autoremovableFormulae = formulae }
        }
    }

    /// Applies `update` unless something asked for later is already shown; returns whether it did.
    private func applier(_ scope: Scope, _ startedAt: Date, _ update: @escaping (BrewStore) -> Void) -> () -> Bool {
        {
            guard self.accept(scope, startedAt: startedAt) else { return false }
            update(self)
            return true
        }
    }

    private func accept(_ scope: Scope, startedAt: Date) -> Bool {
        guard startedAt >= appliedAt[scope, default: .distantPast] else { return false }
        appliedAt[scope] = startedAt
        loaded.insert(scope)
        return true
    }

    private var liveSnapshot: Snapshot {
        Snapshot(
            outdatedPackages: outdated,
            doctorWarnings: doctorWarnings,
            services: services,
            installedCasks: installedCasks,
            cleanupBytesReclaimable: cleanupBytesReclaimable,
            autoremovableFormulae: autoremovableFormulae
        )
    }

    private func saveSnapshot() async {
        guard let historyStore else { return }
        let snapshot = liveSnapshot
        do {
            try await historyStore.save(snapshot)
            lastSavedSnapshotID = snapshot.id
        } catch {
            await logger.log("BrewStore: saving a snapshot failed — \(error.localizedDescription)", .error)
        }
    }

    private func recentSnapshots() async -> [Snapshot] {
        guard let historyStore else { return [] }
        return await (try? historyStore.loadRecent()) ?? []
    }
}
