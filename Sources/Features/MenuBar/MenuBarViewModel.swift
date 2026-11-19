import BrewCore
import Foundation

@MainActor
@Observable
final class MenuBarViewModel {
    @ObservationIgnored private let service: any BrewServicing
    @ObservationIgnored private let notifier: BrewNotifier?
    /// Where the brew state this popover shows lives — shared with the Dashboard and the checker.
    let store: BrewStore
    @ObservationIgnored private var upgradeTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var autoremoveTask: Task<Void, Never>?
    /// Set once a real curl percentage has arrived, so the simulated ticker below
    /// never steps the bar backward — same contract as `DashboardViewModel.installProgress`.
    @ObservationIgnored private var upgradeLogLastIsProgress = false
    @ObservationIgnored private var progressSimulationTask: Task<Void, Never>?

    var outdatedPackages: [OutdatedPackage] {
        store.outdated
    }

    /// The findings not ignored — what the icon, `status` and the popover count.
    var visibleDoctorWarnings: [DoctorWarning] {
        store.visibleDoctorWarnings
    }

    /// The ones the user ignored, still listed on the Doctor page so they can be brought back.
    var ignoredDoctorWarnings: [DoctorWarning] {
        store.ignoredDoctorWarnings
    }

    /// When `brew doctor` last ran — nil before its first run.
    var doctorCheckedAt: Date? {
        store.doctorCheckedAt
    }

    /// Why the last `brew doctor` run failed. The list stays as the run before left it.
    var doctorFailure: String? {
        store.failures[.doctor]
    }

    var isRunningDoctor: Bool {
        isRunningDoctorHere || store.isRefreshing(.doctor)
    }

    /// What a Dashboard page built on a check shows (Doctor, Updates). `.checked` is the only state
    /// with a list — and so the only one that can say "no warnings" or "up to date": before the
    /// first check, or after it failed, an empty list read as an all-clear.
    enum CheckState: Equatable {
        case running, failed(String), notChecked, checked
    }

    var doctorPage: CheckState {
        if doctorCheckedAt != nil { return .checked }
        if isRunningDoctor { return .running }
        if let doctorFailure { return .failed(doctorFailure) }
        return .notChecked
    }

    /// Whether the last run really found nothing — a failed re-check shows its failure instead,
    /// and ignored findings still need their list, to be brought back from.
    var doctorFoundNothing: Bool {
        doctorPage == .checked && visibleDoctorWarnings.isEmpty && ignoredDoctorWarnings.isEmpty && doctorFailure == nil
    }

    /// "2 doctor warnings · 1 ignored · Last checked 5 minutes ago".
    var doctorSubtitle: String {
        let count = visibleDoctorWarnings.count
        var parts = [count == 1 ? L("1 doctor warning") : L("\(count) doctor warnings")]
        if !ignoredDoctorWarnings.isEmpty { parts.append(L("\(ignoredDoctorWarnings.count) ignored")) }
        if let doctorCheckedAt {
            parts.append(L("Last checked \(doctorCheckedAt.formatted(.relative(presentation: .named)))"))
        }
        return parts.joined(separator: " · ")
    }

    /// Why the last read of the outdated list failed. A list from an earlier check stays on screen.
    var outdatedFailure: String? {
        store.failures[.outdated]
    }

    var servicesFailure: String? {
        store.failures[.services]
    }

    /// The Updates page, on the same terms as `doctorPage`. Before the first check, a failure is
    /// usually the bootstrap's (Homebrew not found), which only `lastError` carries.
    var updatesPage: CheckState {
        if lastChecked != nil { return .checked }
        if isRefreshing { return .running }
        if let failure = outdatedFailure ?? store.lastError { return .failed(failure) }
        return .notChecked
    }

    /// The Updates page's subtitle: what's running, or how many upgrades there are.
    var updatesSubtitle: String {
        if isUpgrading { return isWaitingBehindBrew ? L("Waiting for another Homebrew command…") : L("Upgrading…") }
        let count = outdatedPackages.count
        return count == 1 ? L("1 upgrade available") : L("\(count) upgrades available")
    }

    /// Why the last start/stop of a service failed — for the Dashboard's Services page; the
    /// popover shows the same through `status`. Cleared by the next one that works.
    private(set) var serviceActionFailure: String?
    /// Same, for Clean Up and Remove unused, which the Dashboard runs from its Insights page.
    private(set) var maintenanceFailure: String?

    /// Whether Updates can say "up to date": an empty list from a check that worked.
    var isUpToDate: Bool {
        outdatedPackages.isEmpty && outdatedFailure == nil && upgradeFailure == nil
    }

    /// What the Services page shows as failed: the user's own start/stop first, then the read.
    var servicesPageFailure: String? {
        serviceActionFailure ?? servicesFailure
    }

    var servicesFoundNothing: Bool {
        visibleServices.isEmpty && servicesPageFailure == nil
    }

    var insightsFoundNothing: Bool {
        insights.isEmpty && maintenanceFailure == nil
    }

    var insights: [Insight] {
        store.insights
    }

    var services: [ServiceEntry] {
        store.services
    }

    var lastChecked: Date? {
        store.lastChecked
    }

    /// The formulae `brew autoremove` would uninstall — what the removal confirmation lists.
    var autoremovableFormulae: [String] {
        store.autoremovableFormulae
    }

    /// Worked out from the store each time it's read, not kept: it used to be a stored value that
    /// every path had to remember to recompute, and an action's error stayed up (hiding the update
    /// count) until one of them did. Priority: error > doctor error > doctor warnings > updates > ok.
    var status: MenuBarStatus {
        if let error = store.lastError { return .error(error) }
        guard lastChecked != nil else { return .initializing }
        if visibleDoctorWarnings.contains(where: { $0.severity == .error }) {
            // Never send the user to Terminal: that's the one thing this app exists
            // to make unnecessary. The detail (and whatever `brew doctor` actually
            // said) is already a tap away, in the Doctor Warnings list this very
            // popover shows below.
            return .error(L("Homebrew needs attention — see Doctor Warnings below."))
        }
        if !visibleDoctorWarnings.isEmpty { return .warning(count: visibleDoctorWarnings.count) }
        return outdatedPackages.isEmpty ? .ok : .updates(count: outdatedPackages.count)
    }

    private(set) var upgradeLog: [String] = []
    /// Real `curl` download percentage (0...1), backed by a simulated fallback for
    /// the phases brew reports no percentage at all — see `appendUpgradeProgress`/
    /// `startProgressSimulation`. `nil` before anything has arrived yet, so the view
    /// can tell "no data" from "0%".
    private(set) var upgradeProgress: Double?
    /// Why the last upgrade failed, or nil. Kept separate from `status`, which also
    /// carries unrelated errors (e.g. `brew doctor` findings) and would be ambiguous.
    private(set) var upgradeFailure: String?
    /// Full text for "Copy error": the command, exit code and output. `upgradeFailure` stays the
    /// short message shown in the sheet.
    private(set) var upgradeFailureDetails: String?
    /// Whether the last upgrade was "Upgrade All" (true) or a single package (false) — decides
    /// whether a Retry in the popup means the same thing as the button that started it.
    private(set) var lastUpgradeWasAll = false
    /// From Cancel until the upgrade has really stopped (and the list has been re-read) — the sheet
    /// showed "Upgrading…" with a Cancel that did nothing in that stretch.
    private(set) var isCancellingUpgrade = false
    /// Whether the last upgrade was stopped by Cancel, which records no failure: the sheet ended
    /// on a green "Done".
    private(set) var upgradeWasCancelled = false

    /// Where the upgrade sheet's run stands — what its title, icon and announcement follow.
    enum UpgradePhase: Equatable {
        case running, cancelling, cancelled, failed, done
    }

    var upgradePhase: UpgradePhase {
        if isCancellingUpgrade { return .cancelling }
        if isRunningAnyUpgrade { return .running }
        if upgradeWasCancelled { return .cancelled }
        return upgradeFailure == nil ? .done : .failed
    }

    private(set) var cleanupLog: [String] = []
    private(set) var autoremoveLog: [String] = []
    /// This view model's own refresh/bootstrap — set synchronously, so it's also the guard against
    /// a second click. `isRefreshing` adds any update check running elsewhere.
    private var isRefreshingHere = false
    var isRefreshing: Bool {
        isRefreshingHere || store.isCheckingForUpdates
    }

    /// Same job as `isRefreshingHere`, for `runDoctor()`.
    private var isRunningDoctorHere = false

    private(set) var isUpgrading: Bool = false
    private(set) var isCleaningUp: Bool = false
    private(set) var isRemovingUnusedDependencies: Bool = false
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

    /// The shared operation log (see `BrewOperations`). Read-only here: the service is the source of
    /// truth for what brew is doing. The busy flags above stay as synchronous guards.
    private let operations: BrewOperations?
    private let logger: BrewLogger

    /// Without a `store`, it gets its own over `service` (tests that only look at the menu bar).
    init(
        service: any BrewServicing,
        notifier: BrewNotifier? = nil,
        historyStore: HistoryStore? = nil,
        operations: BrewOperations? = nil,
        store: BrewStore? = nil,
        logger: BrewLogger = .shared
    ) {
        self.service = service
        self.notifier = notifier
        self.store = store ?? BrewStore(service: service, historyStore: historyStore, notifier: notifier)
        self.operations = operations
        self.logger = logger
    }

    /// True while some mutating brew command is waiting for Homebrew's gate. An upgrade started
    /// from here can sit in that queue, so the UI says so instead of looking stuck.
    var isWaitingBehindBrew: Bool {
        operations?.queued.isEmpty == false
    }

    // MARK: - Public API (sync — called from SwiftUI body)

    func start(customBrewPath: String? = nil) {
        Task { await performBootstrap(customBrewPath: customBrewPath) }
    }

    func refresh() {
        guard !isRefreshing, !isRunningAnyUpgrade else { return }
        // Set before the Task, not inside it — otherwise two calls in a row both pass the guard.
        isRefreshingHere = true
        Task {
            defer { isRefreshingHere = false }
            let failures = await store.checkForUpdates()
            if let error = failures[.outdated] ?? failures[.services] {
                store.report(message(from: error))
            }
        }
    }

    /// The Doctor page's Check Again: shows a fix the user just made now, not at the next daily run.
    func runDoctor() {
        guard !isRunningDoctor else { return }
        // Set before the Task, same as `refresh()`.
        isRunningDoctorHere = true
        Task {
            defer { isRunningDoctorHere = false }
            await store.runDoctor()
        }
    }

    /// BrewMenu's own cask is left out of "Upgrade All": replacing the running app from inside
    /// the run would pull the app out from under itself. It keeps its own Update button, which
    /// asks for a restart afterwards.
    static let selfCaskName = "brewmenu"

    static func bulkUpgradeTargets(_ packages: [OutdatedPackage]) -> [OutdatedPackage] {
        packages.filter { !($0.isCask && $0.name == selfCaskName) }
    }

    /// Packages "Upgrade All" will actually touch — the count the user is shown and confirms.
    var bulkUpgradeCount: Int {
        Self.bulkUpgradeTargets(outdatedPackages).count
    }

    /// Returns whether it started — a caller that raises the log sheet doesn't raise it over a run
    /// that never began (a check started meanwhile, say), which showed an empty "Done".
    @discardableResult
    func upgradeAll() -> Bool {
        // Any upgrade, not just another Upgrade All: a single one running shares `upgradeTask`, and
        // starting this over it left the single one with no way to cancel it.
        guard !isRunningAnyUpgrade, !isRefreshing, !isCleaningUp, !isRemovingUnusedDependencies,
              bulkUpgradeCount > 0 else { return false }
        // Set before the Task, not inside it — otherwise two clicks in a row both pass the guard.
        isUpgrading = true
        upgradeTask = Task { await performUpgradeAll() }
        return true
    }

    /// Returns whether it started (see `upgradeAll()`).
    @discardableResult
    func upgradePackage(_ name: String) -> Bool {
        // One upgrade at a time: they share `upgradeTask`, the log and the progress bar, so a second
        // one started mid-run took over all three and left the first with no way to cancel it.
        guard !isRunningAnyUpgrade else { return false }
        upgradingPackages.insert(name)
        upgradeLog = []
        upgradeProgress = nil
        upgradeLogLastIsProgress = false
        upgradeFailure = nil
        upgradeFailureDetails = nil
        upgradeWasCancelled = false
        lastUpgradeWasAll = false
        startProgressSimulation()
        upgradeTask = Task {
            defer {
                upgradingPackages.remove(name)
                upgradeTask = nil
                isCancellingUpgrade = false
                stopProgressSimulation()
            }
            do {
                try await syncDatabaseBeforeUpgrading()
                // No `[weak self]` here: the enclosing `Task { ... }` already captures
                // `self` strongly (it reads `upgradingPackages`/`needsRestart` directly
                // below), so weakening just this inner closure contradicts that outer
                // capture instead of actually avoiding a retain cycle — hence the
                // compiler warning this used to trigger.
                let output = makeOrderedStream { (event: CommandOutputEvent) in
                    switch event {
                    case let .line(line): self.appendUpgradeLine(line)
                    case let .progress(text): self.appendUpgradeProgress(text)
                    }
                }
                defer { output.finish() }
                try await service.runUpgrade(name) { output.send(.line($0)) } onProgress: {
                    output.send(.progress($0))
                }
                if name == "brewmenu" { needsRestart = true }
                try await refreshAfterUpgrade()
            } catch is CancellationError {
                // Same as Upgrade All: the cancel is not a failure, and the list needs a re-check.
                upgradeWasCancelled = true
                await refreshAfterCancelledUpgrade()
            } catch {
                upgradeFailure = message(from: error)
                upgradeFailureDetails = (error as? BrewError)?.details ?? upgradeFailure
                // A failed run can still have upgraded the package (only its post-install step
                // failed, say), so the list is re-read before the error goes up.
                try? await refreshState(after: .upgrade)
                store.report(message(from: error))
            }
        }
        return true
    }

    /// A real completed line from brew — always appended, and it always ends any
    /// in-place progress-update streak (see `appendUpgradeProgress`).
    private func appendUpgradeLine(_ line: String) {
        upgradeLog.append(line)
        upgradeLogLastIsProgress = false
    }

    /// A `\r`-terminated in-place update (a download percentage, typically) — same
    /// parsing and in-place log replacement as `DashboardViewModel.appendInstallProgress`.
    private func appendUpgradeProgress(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let percent = CommandProgress.parsePercent(from: trimmed) {
            upgradeProgress = max(upgradeProgress ?? 0, percent)
        }
        if upgradeLogLastIsProgress, !upgradeLog.isEmpty {
            upgradeLog[upgradeLog.count - 1] = trimmed
        } else {
            upgradeLog.append(trimmed)
            upgradeLogLastIsProgress = true
        }
    }

    /// Same simulated fallback curve as installs — see `DashboardViewModel.startProgressSimulation`.
    private func startProgressSimulation() {
        progressSimulationTask?.cancel()
        let start = Date()
        progressSimulationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                let simulated = CommandProgress.simulated(elapsedSeconds: elapsed)
                upgradeProgress = max(upgradeProgress ?? 0, simulated)
            }
        }
    }

    private func stopProgressSimulation() {
        progressSimulationTask?.cancel()
        progressSimulationTask = nil
    }

    /// True while any upgrade is running, single-package or Upgrade All. The popup uses this
    /// so a single upgrade shows as running, not as "Done" before brew has finished.
    var isRunningAnyUpgrade: Bool {
        isUpgrading || !upgradingPackages.isEmpty
    }

    /// Called when the user closes the upgrade sheet after a failure — which the menu bar icon
    /// drops too, instead of staying red until the next check.
    func clearUpgradeFailure() {
        if let upgradeFailure { store.withdraw(upgradeFailure) }
        upgradeFailure = nil
    }

    func cancelUpgrade() {
        guard let upgradeTask else { return }
        isCancellingUpgrade = true
        upgradeTask.cancel()
        self.upgradeTask = nil
    }

    /// Reclaims disk space via `brew cleanup` — deletes old package versions and
    /// cached downloads, so unlike `upgradeAll` this needs an explicit confirmation
    /// in the UI before it's ever called.
    func cleanUp() {
        guard !isCleaningUp, !isRunningAnyUpgrade, !isRefreshing else { return }
        isCleaningUp = true // Before the Task, same as `upgradeAll()`.
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
        guard !isRemovingUnusedDependencies, !isRunningAnyUpgrade, !isRefreshing, !isCleaningUp else { return }
        isRemovingUnusedDependencies = true // Before the Task, same as `upgradeAll()`.
        autoremoveTask = Task { await performAutoremove() }
    }

    func cancelRemoveUnusedDependencies() {
        autoremoveTask?.cancel()
        autoremoveTask = nil
    }

    // MARK: - Doctor fixes

    /// The doctor fix running now — its command line. One at a time, like every brew command.
    private(set) var runningDoctorFix: String?
    /// The running fix's latest line, shown under its command.
    private(set) var doctorFixLastLine: String?

    struct DoctorFixFailure: Equatable {
        let command: String
        let message: String
    }

    private(set) var doctorFixFailure: DoctorFixFailure?
    @ObservationIgnored private var doctorFixTask: Task<Void, Never>?

    /// Whether BrewMenu runs `command` itself: a plain `brew` command of a kind it runs anyway
    /// (upgrade, reinstall, cleanup…). The rest — `sudo`, shell profile edits — stay the user's.
    static func canRunDoctorFix(_ command: String) -> Bool {
        DoctorWarning.brewArguments(of: command).flatMap(BrewOperations.Kind.init(fixArguments:)) != nil
    }

    /// Runs a fix from the Doctor page, then refreshes what it changed and runs `brew doctor` again:
    /// a fix that worked is a finding that goes away, without a Check Again.
    func runDoctorFix(_ command: String) {
        guard runningDoctorFix == nil, let arguments = DoctorWarning.brewArguments(of: command),
              let kind = BrewOperations.Kind(fixArguments: arguments) else { return }
        runningDoctorFix = command
        doctorFixLastLine = nil
        doctorFixFailure = nil
        doctorFixTask = Task {
            defer {
                runningDoctorFix = nil
                doctorFixTask = nil
            }
            do {
                // No `[weak self]`: the Task already holds `self` (see `upgradePackage`).
                let lines = makeOrderedStream { (line: String) in self.doctorFixLastLine = line }
                defer { lines.finish() }
                try await service.runDoctorFix(arguments) { lines.send($0) }
            } catch is CancellationError {
                return
            } catch {
                doctorFixFailure = DoctorFixFailure(command: command, message: message(from: error))
                return
            }
            doctorFixLastLine = L("Checking again…")
            await store.refresh(after: kind)
            await store.runDoctor()
        }
    }

    func cancelDoctorFix() {
        doctorFixTask?.cancel()
    }

    /// A finding's fix as the Doctor page shows it: brew's own steps, plus — for the packages it's
    /// about that nothing installed needs any more — removing them. brew's text for a deprecated
    /// package left behind as an unused dependency only says to "find replacements"; the fix that
    /// applies is uninstalling it.
    func fixSteps(for warning: DoctorWarning) -> [DoctorWarning.FixStep] {
        let unused = warning.affectedPackages.filter(store.autoremovableFormulae.contains)
        guard !unused.isEmpty else { return warning.fixSteps }
        return warning.fixSteps + [
            .text(L("Nothing installed uses \(unused.joined(separator: ", ")) any more, so it can simply be removed:")),
            .command("brew uninstall " + unused.joined(separator: " ")),
        ]
    }

    /// Why a fix stays the user's to run — shown under it.
    static func whyDoctorFixIsForTerminal(_ command: String) -> String {
        if command.hasPrefix("sudo ") {
            return L("It needs your administrator password, so it's for Terminal.")
        }
        if command.contains(">>") || command.contains("export ") {
            return L("It changes your shell's setup, so it's for Terminal.")
        }
        return L("BrewMenu doesn't run this kind of command, so it's for Terminal.")
    }

    // MARK: - Services

    /// For the Dashboard's Services page — the timer only polls them while the popover is open.
    func refreshServices() async {
        await store.refresh([.services])
    }

    func startService(_ name: String) {
        toggleService(name) { try await $0.startService(name) }
    }

    func stopService(_ name: String) {
        toggleService(name) { try await $0.stopService(name) }
    }

    private func toggleService(_ name: String, _ action: @escaping (any BrewServicing) async throws -> Void) {
        guard !togglingServices.contains(name) else { return }
        togglingServices.insert(name)
        Task {
            defer { togglingServices.remove(name) }
            do {
                try await action(service)
            } catch {
                // Per SPECT: show error message, don't escalate privileges.
                serviceActionFailure = message(from: error)
                store.report(message(from: error))
                return
            }
            clearActionFailure(\.serviceActionFailure)
            // The start/stop worked; a failed read afterwards is the list's problem, and
            // `servicesFailure` shows it.
            if let error = await store.refresh([.services])[.services] { store.report(message(from: error)) }
        }
    }

    // MARK: - Internal async (exposed for testing)

    func performBootstrap(customBrewPath: String? = nil) async {
        isRefreshingHere = true
        defer { isRefreshingHere = false }
        do {
            try await service.bootstrap(customBrewPath: customBrewPath)
            await store.restoreFromHistory()
            try await refreshState()
        } catch let e as BrewError {
            if case .notFound = e {
                store.report(L("Homebrew not found. Set the path in Settings."))
            } else {
                store.report(message(from: e))
            }
        } catch {
            store.report(message(from: error))
        }
    }

    func performUpgradeAll() async {
        let countBeforeUpgrade = Self.bulkUpgradeTargets(outdatedPackages).count
        upgradeLog = []
        upgradeProgress = nil
        upgradeLogLastIsProgress = false
        upgradeFailure = nil
        upgradeFailureDetails = nil
        upgradeWasCancelled = false
        lastUpgradeWasAll = true
        isUpgrading = true
        startProgressSimulation()
        defer {
            isUpgrading = false
            upgradeTask = nil
            isCancellingUpgrade = false
            stopProgressSimulation()
        }
        do {
            try await syncDatabaseBeforeUpgrading()
            let output = makeOrderedStream { [weak self] (event: CommandOutputEvent) in
                switch event {
                case let .line(line): self?.appendUpgradeLine(line)
                case let .progress(text): self?.appendUpgradeProgress(text)
                }
            }
            defer { output.finish() }
            try await service.runUpgradeAll(
                names: Self.bulkUpgradeTargets(outdatedPackages).map(\.name)
            ) { output.send(.line($0)) } onProgress: {
                output.send(.progress($0))
            }
            await notifier?.resetAfterUpgrade()
            try await refreshAfterUpgrade()
            await notifier?.notifyUpgradeCompleted(count: countBeforeUpgrade)
        } catch is CancellationError {
            // Packages that finished before the cancel are no longer outdated, so the
            // list has to be re-checked.
            upgradeWasCancelled = true
            await refreshAfterCancelledUpgrade()
        } catch {
            let reason = message(from: error)
            upgradeFailure = reason
            upgradeFailureDetails = (error as? BrewError)?.details ?? reason
            // Same as a single upgrade: whatever did get upgraded must leave the list.
            try? await refreshState(after: .upgrade)
            store.report(reason)
            if countBeforeUpgrade > 0 {
                await notifier?.notifyUpgradeFailed(reason: reason)
            }
        }
    }

    func performCleanUp() async {
        cleanupLog = []
        // A new run replaces the last one's failure — also when this one ends up cancelled.
        clearActionFailure(\.maintenanceFailure)
        isCleaningUp = true
        defer {
            isCleaningUp = false
            cleanupTask = nil
        }
        do {
            let lines = makeOrderedStream { [weak self] (line: String) in self?.cleanupLog.append(line) }
            defer { lines.finish() }
            try await service.runCleanup { lines.send($0) }
            // Records a fresh snapshot with the post-cleanup byte count so the
            // "Cleanup pending" insight clears immediately — without this it would
            // keep citing the pre-cleanup number until StatusChecker's next
            // scheduled run, even though the space is already back.
            do {
                try await refreshState(after: .cleanup, recordSnapshot: true)
            } catch {
                store.report(message(from: error)) // The cleanup itself worked.
            }
        } catch is CancellationError {
            // Not a failure.
        } catch {
            maintenanceFailure = message(from: error)
            store.report(message(from: error))
        }
    }

    func performAutoremove() async {
        autoremoveLog = []
        // A new run replaces the last one's failure — also when this one ends up cancelled.
        clearActionFailure(\.maintenanceFailure)
        isRemovingUnusedDependencies = true
        defer {
            isRemovingUnusedDependencies = false
            autoremoveTask = nil
        }
        do {
            let lines = makeOrderedStream { [weak self] (line: String) in self?.autoremoveLog.append(line) }
            defer { lines.finish() }
            try await service.runAutoremove { lines.send($0) }
            // Same reasoning as performCleanUp: record the post-removal state right
            // away instead of waiting on StatusChecker's next scheduled run so the
            // "Unused dependencies" insight clears immediately.
            do {
                try await refreshState(after: .autoremove, recordSnapshot: true)
            } catch {
                store.report(message(from: error)) // The removal itself worked.
            }
        } catch is CancellationError {
            // Not a failure.
        } catch {
            maintenanceFailure = message(from: error)
            store.report(message(from: error))
        }
    }

    // MARK: - Private

    /// Refetches what `kind` can have changed (see `BrewStore.scopes(after:)`), or by default the
    /// outdated list and services. Throws when either of those two couldn't be read.
    private func refreshState(after kind: BrewOperations.Kind? = nil, recordSnapshot: Bool = false) async throws {
        let failures = if let kind {
            await store.refresh(after: kind, recordSnapshot: recordSnapshot)
        } else {
            await store.refresh([.outdated, .services])
        }
        if let error = failures[.outdated] ?? failures[.services] { throw error }
    }

    /// An upgrade from a stale database would install whatever version was current back then, so
    /// it's brought up to date first (see `BrewStore.syncDatabaseIfStale`), and the log says so.
    private func syncDatabaseBeforeUpgrading() async throws {
        await store.syncDatabaseIfStale { appendUpgradeLine(L("Updating the package database…")) }
        try Task.checkCancellation()
    }

    /// The re-read after an upgrade brew finished, in its own Task: a Cancel clicked during it (the
    /// sheet still shows Cancel) would otherwise cancel every read, leave the upgraded packages in
    /// the list, and call a finished run "cancelled".
    private func refreshAfterUpgrade() async throws {
        try await Task { try await refreshState(after: .upgrade) }.value
    }

    /// The upgrade's task is already cancelled here, so the re-check runs in a fresh, uncancelled
    /// Task (unstructured Tasks don't inherit it).
    private func refreshAfterCancelledUpgrade() async {
        do {
            try await Task { try await refreshState(after: .upgrade) }.value
        } catch {
            store.report(message(from: error))
        }
    }

    private func message(from error: Error) -> String {
        error.localizedDescription
    }

    /// After an action worked: its earlier failure goes, from this page and from the menu bar.
    private func clearActionFailure(_ failure: ReferenceWritableKeyPath<MenuBarViewModel, String?>) {
        if let previous = self[keyPath: failure] { store.withdraw(previous) }
        self[keyPath: failure] = nil
    }
}
