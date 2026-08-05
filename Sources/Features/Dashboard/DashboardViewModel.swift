import Foundation

/// Identifies which package's detail sheet is open — `Identifiable` so it can drive
/// `.sheet(item:)` directly.
struct PackageDetailTarget: Identifiable, Hashable {
    let name: String
    let isCask: Bool
    var id: String { "\(name)-\(isCask)" }
}

/// What the "Add" sheet's free-text field currently looks like, per Homebrew's own
/// naming rules — this is what lets one field replace separate "Add a Tap" /
/// "Install a Package" actions: a bare name or `user/repo/name` can only ever be a
/// formula/cask (Homebrew requires 3 segments to name a package outside the default
/// taps), while a plain `user/repo` can only ever be a tap (installing needs a third
/// segment). No brew call is needed to tell these apart — only the package case then
/// needs an actual `brew info` lookup to know formula vs. cask.
enum AddInputKind: Equatable {
    case invalid
    case tap(name: String)
    case packageCandidate(name: String)

    private static let segmentPattern = #"^[\w][\w.+@-]*$"#

    static func classify(_ raw: String) -> AddInputKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        func validSegments() -> Bool {
            segments.allSatisfy { $0.range(of: segmentPattern, options: .regularExpression) != nil }
        }
        switch segments.count {
        case 1: return validSegments() ? .packageCandidate(name: trimmed) : .invalid
        case 2: return validSegments() ? .tap(name: trimmed) : .invalid
        case 3: return validSegments() ? .packageCandidate(name: trimmed) : .invalid
        default: return .invalid
        }
    }

    /// Strips shell/doc boilerplate someone is likely to paste verbatim — the exact
    /// `brew install --cask user/repo/name` line copied from this app's own package
    /// detail sheet, from Homebrew's website, or from a README — down to the bare
    /// identifier, so pasting the whole line works exactly like pasting just the name.
    /// A no-op on already-bare input (the common case), so it's safe to call unconditionally.
    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let promptRange = text.range(of: #"^[$#%>]\s+"#, options: .regularExpression) {
            text.removeSubrange(promptRange)
        }
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.first?.lowercased() == "brew" { tokens.removeFirst() }
        if let first = tokens.first?.lowercased(), ["install", "tap", "reinstall"].contains(first) {
            tokens.removeFirst()
        }
        tokens.removeAll { $0.hasPrefix("-") }
        return tokens.first ?? text
    }
}

@MainActor
@Observable
final class DashboardViewModel {
    private let service: any BrewServicing
    private let apiClient: any HomebrewAPIServicing
    private let installedPackagesCache: InstalledPackagesCache
    private let logger = BrewLogger.shared

    /// True for the duration of the first `load()` — lets Home/Installed show a
    /// spinner instead of their empty state while waiting on `waitUntilConfigured()`
    /// (which can otherwise take a moment right after launch), so "0 packages" never
    /// briefly reads as "nothing installed" on a machine that has plenty.
    private(set) var isLoading = false
    private(set) var installedPackages: [InstalledPackage] = [] {
        didSet {
            installedByName = Dictionary(installedPackages.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            packagesByCategory = Dictionary(grouping: installedPackages, by: \.category)
        }
    }
    /// Name-keyed mirror of `installedPackages`, kept in sync via `didSet` — lets
    /// `isInstalled`/`isOutdated` do an O(1) lookup instead of re-scanning the whole
    /// array on every row, in every list that shows an install-state badge. Left
    /// Observable (not `@ObservationIgnored`) so rows reading it still get invalidated
    /// when it changes.
    private var installedByName: [String: InstalledPackage] = [:]
    /// Category-grouped mirror of `installedPackages`, kept in sync via `didSet` —
    /// `activeCategories`/`packages(in:)`/`count(in:)` otherwise each re-ran
    /// `PackageCategory.classify` (a ~90-check substring scan) over the whole list on
    /// every access, and the sidebar reads `count(in:)` twice per category per render.
    private var packagesByCategory: [PackageCategory: [InstalledPackage]] = [:]
    private(set) var taps: [Tap] = []
    private(set) var trendingFormulae: [TrendingPackage] = []
    private(set) var trendingCasks: [TrendingPackage] = []
    private(set) var installPacks: [InstallPack] = []
    private(set) var recommendedTaps: [RecommendedTap] = []
    private(set) var installingNames: Set<String> = []
    private(set) var failedInstallNames: Set<String> = []
    /// The real reason each failed install failed (e.g. Homebrew's own "there's
    /// already an App at /Applications/X.app" conflict message) — every row showing
    /// "Install failed" used to hardcode the same generic "check the name and try
    /// again" regardless of cause, hiding an error that was often specific and
    /// actionable (name typo vs. an existing app in the way vs. a network failure
    /// are very different problems with very different fixes).
    private(set) var installErrors: [String: String] = [:]
    private(set) var installLog: [String] = []
    /// True while the install-progress sheet is on screen — stays true after the
    /// underlying process finishes, until the user dismisses it via
    /// `dismissInstallSheet()`. Also doubles as the "another install session is
    /// already up" guard for starting a new one.
    private(set) var isInstalling: Bool = false
    /// True only while a `brew install` is actually in flight — distinct from
    /// `isInstalling` so the sheet can tell "still running" (Cancel) apart from
    /// "finished, waiting for you to look at it" (Done) instead of closing itself
    /// the instant the process exits and yanking away caveats/warnings brew just
    /// printed.
    private(set) var isInstallRunning: Bool = false
    @ObservationIgnored private var installTask: Task<Void, Never>?

    private(set) var uninstallingNames: Set<String> = []
    private(set) var failedUninstallNames: Set<String> = []

    var searchQuery: String = ""
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching: Bool = false
    private var searchTask: Task<Void, Never>?

    var selectedPackageDetailTarget: PackageDetailTarget?
    private(set) var packageDetail: PackageDetail?
    private(set) var isLoadingPackageDetail = false

    private(set) var isAddingTap = false
    private(set) var addTapError: String?
    private(set) var removingTapNames: Set<String> = []

    /// Every formula/cask each tap offers, keyed by tap name — fetched lazily
    /// (see `loadTapPackages(for:)`), since it's only needed to fill in a tap
    /// section that has nothing installed from it yet.
    private(set) var tapPackages: [String: [SearchResult]] = [:]
    /// Pure re-entrancy guard for `loadTapPackages(for:)` — deliberately not
    /// Observable-tracked. `AvailableTapPackageSection`'s `.task` both writes this
    /// (via `loadTapPackages`) and its own body read whether a tap "is loading" —
    /// wiring that through this shared, tracked property created a closed loop in
    /// SwiftUI's attribute graph (write → dirties this view's subgraph → body
    /// re-runs → `.task` re-evaluated → write again), confirmed via `sample` pegging
    /// the main thread at 70-95% CPU continuously. The UI-facing loading flag now
    /// lives in that view's own `@State` instead; this only prevents two concurrent
    /// fetches for the same tap.
    @ObservationIgnored private(set) var loadingTapPackagesFor: Set<String> = []
    /// Set only when the fetch itself failed — kept separate from `tapPackages`
    /// so a failure (network hiccup, `brew tap-info` erroring) reads as "couldn't
    /// load, tap to retry" rather than being cached forever as "this tap has
    /// nothing in it," which used to be indistinguishable from a real empty tap.
    private(set) var tapPackagesError: [String: String] = [:]
    /// Taps that have already gotten their one automatic retry after a cancelled
    /// `loadTapPackages` — see `scheduleAutoRetryOnce(for:)`. Bounds it to exactly
    /// once per tap per app session; not Observable-tracked for the same reason as
    /// `loadingTapPackagesFor`.
    @ObservationIgnored private var autoRetriedTaps: Set<String> = []

    private(set) var addInputKind: AddInputKind = .invalid
    private(set) var isResolvingPackage = false
    private(set) var resolvedPackage: ResolvedPackage?
    private(set) var resolvePackageError: String?

    init(
        service: any BrewServicing,
        apiClient: any HomebrewAPIServicing = HomebrewAPIClient(),
        installedPackagesCache: InstalledPackagesCache = InstalledPackagesCache()
    ) {
        self.service = service
        self.apiClient = apiClient
        self.installedPackagesCache = installedPackagesCache
        self.installPacks = Self.loadBundledInstallPacks()
        self.recommendedTaps = Self.loadBundledRecommendedTaps()
    }

    // MARK: - Loading

    func load() async {
        await logger.log("DashboardViewModel: load() started")
        // Paint the last-known installed list instantly (if any) instead of blocking
        // every launch on a fresh `brew info --json=v2 --installed` subprocess spawn —
        // see InstalledPackagesCache. Only a genuine first-ever launch (nothing cached
        // yet) still shows the spinner below while the real fetch completes.
        let hadCache = await primeFromCacheIfNeeded()
        // load() can run before BrewService.bootstrap() (kicked off separately from
        // BrewMenuApp.init()) has finished — e.g. the Dashboard window opens moments
        // after launch. Waiting on the real signal here (resumed the instant
        // bootstrap() configures the resolver) replaces a blind fixed-delay retry loop.
        isLoading = !hadCache
        defer { isLoading = false }
        do {
            try await service.waitUntilConfigured()
            async let packages = fetchInstalledPackagesLogged()
            async let fetchedTaps = fetchTapsLogged()
            installedPackages = await packages
            taps = await fetchedTaps
            await installedPackagesCache.save(installedPackages: installedPackages, taps: taps)
            await logger.log("DashboardViewModel: load() got \(installedPackages.count) installed packages, \(taps.count) taps")
        } catch {
            // Bootstrap failed (e.g. Homebrew not found) — degrade to the existing
            // empty installedPackages/taps rather than hanging in isLoading forever.
            // Trending below is independent of local Homebrew and still worth loading.
            await logger.log("DashboardViewModel: load() — Homebrew isn't configured (\(error.localizedDescription))", .error)
        }

        // Trending is network-backed and best-effort — never blocks the rest of Home from
        // rendering, and failures degrade to an empty/stale list rather than surfacing an error.
        async let formulae = (try? apiClient.fetchTrendingFormulae()) ?? []
        async let casks = (try? apiClient.fetchTrendingCasks()) ?? []
        trendingFormulae = await formulae
        trendingCasks = await casks
    }

    func refreshInstalled() async {
        installedPackages = await fetchInstalledPackagesLogged()
        taps = await fetchTapsLogged()
        await installedPackagesCache.save(installedPackages: installedPackages, taps: taps)
    }

    /// Paints `installedPackages`/`taps` from the on-disk cache if nothing's loaded yet.
    /// Returns whether there was anything to show — callers use this to decide whether
    /// the loading spinner is still needed.
    private func primeFromCacheIfNeeded() async -> Bool {
        guard installedPackages.isEmpty else { return true }
        let cached = await installedPackagesCache.installedPackages
        guard !cached.isEmpty else { return false }
        installedPackages = cached
        taps = await installedPackagesCache.taps
        return true
    }

    private func fetchInstalledPackagesLogged() async -> [InstalledPackage] {
        do {
            return try await service.fetchInstalledPackages()
        } catch {
            await logger.log("DashboardViewModel: fetchInstalledPackages failed — \(error.localizedDescription)", .error)
            return []
        }
    }

    private func fetchTapsLogged() async -> [Tap] {
        do {
            return try await service.fetchTaps()
        } catch {
            await logger.log("DashboardViewModel: fetchTaps failed — \(error.localizedDescription)", .error)
            return []
        }
    }

    // MARK: - Ecosystems

    /// Taps with at least one installed package — used for the Home stat card's "Active
    /// ecosystems" count, a measure of how many ecosystems you're actually using.
    var ecosystems: [Tap] {
        let names = Set(installedPackages.map(\.tap))
        return names.sorted().map { Tap(name: $0) }
    }

    private static let officialTapNames: Set<String> = ["homebrew/core", "homebrew/cask"]

    /// Homebrew's own taps — shown as individual sidebar entries. Sourced from
    /// `ecosystems` (installed-based), not `taps`: modern Homebrew serves homebrew/core
    /// and homebrew/cask from a remote API without ever cloning them locally, so they
    /// routinely don't appear in `brew tap` at all — even with plenty installed from
    /// them. (Confirmed on this machine: `brew tap` lists only third-party taps.)
    var officialEcosystems: [Tap] {
        ecosystems.filter { Self.officialTapNames.contains($0.name) }
    }

    /// Every other tap (custom third-party taps like `user/repo`) — grouped under a single
    /// "Third-Party" sidebar entry instead of one row per tap, since these can multiply
    /// quickly and each usually holds just a handful of packages. Unlike core/cask,
    /// third-party taps always require an explicit `brew tap`, so this is the union of
    /// what's tapped (`taps`, including a freshly-added empty one) and what's actually
    /// installed (`ecosystems`, covering a tap that's since been removed from `brew tap`
    /// but still has packages installed from it).
    var thirdPartyTaps: [Tap] {
        let tapped = Set(taps.map(\.name))
        let installed = Set(ecosystems.map(\.name))
        return tapped.union(installed)
            .subtracting(Self.officialTapNames)
            .sorted()
            .map { Tap(name: $0) }
    }

    /// Whether the "Ecosystems" sidebar section should show at all.
    var hasAnyEcosystems: Bool {
        !officialEcosystems.isEmpty || !thirdPartyTaps.isEmpty
    }

    var activeEcosystemsCount: Int { ecosystems.count }

    var installedCount: Int { installedPackages.count }

    /// Names of packages `brew outdated` currently reports as outdated — pushed in from
    /// `MenuBarViewModel.outdatedPackages` (see `DashboardView`), the same source the
    /// popover and the Outdated Packages section already treat as authoritative.
    ///
    /// Deliberately NOT `installedPackages.filter(\.outdated)`: that boolean comes from
    /// `brew info --json=v2 --installed`, fetched (and cached) on its own schedule by
    /// `load()` — it can disagree with `brew outdated`'s live count for as long as this
    /// view model's own `installedPackages` snapshot predates the next background check,
    /// showing e.g. "0 Outdated" here while the Outdated Packages section already lists
    /// packages that need updating.
    private(set) var liveOutdatedNames: Set<String> = []

    func updateLiveOutdatedNames(_ names: Set<String>) {
        liveOutdatedNames = names
    }

    var outdatedInstalledCount: Int { installedPackages.filter { liveOutdatedNames.contains($0.name) }.count }

    func packages(in tap: Tap) -> [InstalledPackage] {
        installedPackages.filter { $0.tap == tap.name }
    }

    /// Adds a third-party tap by hand (`brew tap user/repo`) — e.g. the sidebar's "+"
    /// button next to Third-Party. Returns whether it succeeded so the caller can decide
    /// whether to dismiss its input sheet; `addTapError` carries the failure message for
    /// display, and is cleared at the start of every attempt.
    @discardableResult
    func addTap(_ name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        addTapError = nil
        guard trimmed.range(of: #"^[\w-]+/[\w-]+$"#, options: .regularExpression) != nil else {
            addTapError = L("Enter a tap in the form user/repo.")
            return false
        }

        isAddingTap = true
        defer { isAddingTap = false }
        do {
            try await service.addTap(trimmed, onLine: { _ in })
            taps = await fetchTapsLogged()
            return true
        } catch {
            addTapError = error.localizedDescription
            await logger.log("DashboardViewModel: addTap \(trimmed) failed — \(error.localizedDescription)", .error)
            return false
        }
    }

    /// Reclassifies the unified "Add" sheet's text field on every keystroke — a synchronous,
    /// local call (see `AddInputKind.classify`), so this is safe to run on `.onChange`.
    /// Any previous lookup result is invalidated, since it no longer describes the
    /// current text.
    /// Returns the sanitized text so the caller can write it back into the field —
    /// pasting a full `brew install --cask user/repo/name` should visibly collapse to
    /// just `user/repo/name`, not silently classify differently than what's shown.
    @discardableResult
    func updateAddInput(_ raw: String) -> String {
        let cleaned = AddInputKind.sanitize(raw)
        addInputKind = AddInputKind.classify(cleaned)
        resolvedPackage = nil
        resolvePackageError = nil
        addTapError = nil
        return cleaned
    }

    /// Looks up a formula/cask name (bare or `user/repo/name`) via `brew info`, without
    /// installing anything — lets the "Add" sheet show what it found (formula vs. cask,
    /// its tap, its description) so the user can confirm before anything happens.
    func resolvePackageCandidate(_ raw: String) async {
        guard case .packageCandidate(let name) = AddInputKind.classify(AddInputKind.sanitize(raw)) else { return }
        resolvedPackage = nil
        resolvePackageError = nil
        isResolvingPackage = true
        defer { isResolvingPackage = false }
        do {
            if let resolved = try await service.resolvePackage(name) {
                resolvedPackage = resolved
            } else {
                resolvePackageError = L("Couldn't find a formula or cask named \"\(name)\". Check the spelling, or use the full name (user/repo/name) if it's from a tap you haven't added yet.")
            }
        } catch {
            resolvePackageError = error.localizedDescription
            await logger.log("DashboardViewModel: resolvePackage \(name) failed — \(error.localizedDescription)", .error)
        }
    }

    /// Removes a third-party tap (`brew untap`). Mainly useful for the empty tap a
    /// failed "Install a Package" attempt leaves behind — Homebrew taps the repo before
    /// resolving the formula/cask, so a nonexistent package name still leaves a real,
    /// empty tap on disk even though the install itself failed.
    func removeTap(_ name: String) async {
        guard !removingTapNames.contains(name) else { return }
        removingTapNames.insert(name)
        defer { removingTapNames.remove(name) }
        do {
            try await service.removeTap(name)
            taps = await fetchTapsLogged()
        } catch {
            await logger.log("DashboardViewModel: removeTap \(name) failed — \(error.localizedDescription)", .error)
        }
    }

    /// Lazily fetches every formula/cask a tap offers — for a tap section with
    /// nothing installed from it yet, so there's something to browse and install
    /// instead of a dead end. Successful results are cached per tap name; a failed
    /// fetch is *not* cached, so it's retried the next time this is called (e.g.
    /// the user tapping Retry) instead of being stuck as "empty" for the rest of
    /// the session.
    func loadTapPackages(for tap: String) async {
        guard tapPackages[tap] == nil, !loadingTapPackagesFor.contains(tap) else { return }
        loadingTapPackagesFor.insert(tap)
        defer { loadingTapPackagesFor.remove(tap) }
        do {
            tapPackages[tap] = try await service.fetchTapPackages(tap)
            tapPackagesError[tap] = nil
        } catch is CancellationError {
            // The view driving this (`.task(id: tap)`) gets interrupted mid-fetch by
            // transient SwiftUI/list churn — confirmed happening once or twice right
            // as a new tap appears in the sidebar, settling on its own immediately
            // after. Surfaced as a distinct, retryable state (reusing the existing
            // error branch's Retry button), plus one automatic retry scheduled below —
            // *not* awaited inline here. Awaiting a retry directly inside this
            // cancellation path (tried first, whether from this function or from the
            // view's own `.task`) reintroduced the exact attribute-graph feedback loop
            // this cancellation handling exists to avoid, every time, regardless of
            // delay — confirmed empirically via CPU sampling. A free-floating `Task`,
            // structurally unrelated to whatever view/graph node the original fetch
            // was running under, does not.
            tapPackagesError[tap] = L("Interrupted — tap Retry to try again.")
            scheduleAutoRetryOnce(for: tap)
        } catch {
            tapPackagesError[tap] = error.localizedDescription
            await logger.log("DashboardViewModel: loadTapPackages \(tap) failed — \(error.localizedDescription)", .error)
        }
    }

    /// Schedules exactly one retry of `loadTapPackages(for:)`, a beat later, after a
    /// cancelled attempt — see the comment in `loadTapPackages`'s `CancellationError`
    /// case for why this is a free-floating `Task` rather than an inline `await`.
    private func scheduleAutoRetryOnce(for tap: String) {
        guard !autoRetriedTaps.contains(tap) else { return }
        autoRetriedTaps.insert(tap)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.loadTapPackages(for: tap)
        }
    }

    func isInstalled(_ name: String) -> Bool {
        installedByName[name] != nil
    }

    func isTapped(_ tapName: String) -> Bool {
        taps.contains { $0.name == tapName }
    }

    /// Whether an installed package needs updating — Trending/Recommended/Search rows
    /// otherwise only ever showed a plain "Installed" checkmark even when the package
    /// was actually out of date, unlike `InstalledPackageRow`'s "Outdated" badge.
    func isOutdated(_ name: String) -> Bool {
        liveOutdatedNames.contains(name)
    }

    // MARK: - Categories

    /// Categories with at least one installed package, in a fixed display order —
    /// see `PackageCategory` for how (approximately) packages are classified.
    var activeCategories: [PackageCategory] {
        PackageCategory.displayOrder.filter { packagesByCategory[$0] != nil }
    }

    func packages(in category: PackageCategory) -> [InstalledPackage] {
        packagesByCategory[category] ?? []
    }

    func count(in category: PackageCategory) -> Int {
        packagesByCategory[category]?.count ?? 0
    }

    // MARK: - Description lookups (Recommended for you)

    func description(for package: TrendingPackage) async -> String? {
        try? await apiClient.fetchDescription(name: package.name, isCask: package.isCask)
    }

    /// Deprecated/disabled status for a package not sourced from `brew info --json=v2
    /// --installed` (i.e. not yet installed) — `brew search` results carry only a name,
    /// so Search Results rows fetch this lazily, same pattern as Recommended's
    /// description lookup. Cached 6h by the same on-disk cache as the detail sheet.
    func deprecationStatus(for name: String, isCask: Bool) async -> (deprecated: Bool, disabled: Bool) {
        guard let detail = try? await apiClient.fetchPackageDetail(name: name, isCask: isCask) else {
            return (false, false)
        }
        return (detail.deprecated, detail.disabled)
    }

    // MARK: - Install

    /// Installs one package. On failure, marks `failedInstallNames` (rows read this to
    /// show a distinct "Failed" state instead of silently reverting to "Install" with
    /// zero indication anything went wrong) and appends a visible line to `installLog`
    /// — logging to file alone left the user with no on-screen signal that a click
    /// "did nothing."
    func install(name: String, isCask: Bool) async {
        guard !installingNames.contains(name) else { return }
        installingNames.insert(name)
        failedInstallNames.remove(name)
        installErrors[name] = nil
        defer { installingNames.remove(name) }

        await logger.log("DashboardViewModel: installing \(name)")
        do {
            try await service.installPackage(name, isCask: isCask) { [weak self] line in
                Task { @MainActor in self?.installLog.append(line) }
            }
            await refreshInstalled()
        } catch {
            failedInstallNames.insert(name)
            installErrors[name] = error.localizedDescription
            installLog.append("✗ \(name) failed — \(error.localizedDescription)")
            await logger.log("DashboardViewModel: install \(name) failed — \(error.localizedDescription)", .error)
        }
    }

    /// Kicks off a single ad-hoc install (Search Results, Trending, Home's Recommended,
    /// the package detail sheet) through the same log sheet `installPack` already shows.
    /// Without this, a lone `brew install` sitting on a slow download or a stuck sudo
    /// prompt had nothing on screen but the row's spinner — this gives it the same
    /// visible, scrolling progress instead of leaving the user guessing whether the
    /// click did anything. Serialized against pack installs via `isInstalling`, same as
    /// `installPack` already serializes against itself — running two `brew install`s at
    /// once risks both stepping on Homebrew's own lock/Cellar state.
    func installSingle(name: String, isCask: Bool) {
        guard !isInstalling else { return }
        isInstalling = true
        isInstallRunning = true
        installLog = []
        installTask = Task {
            await install(name: name, isCask: isCask)
            // `install()` already appends a "✗ … failed" line on error — add the
            // matching success line here so a finished sheet always ends on an
            // explicit result instead of just trailing off after the last brew line.
            if !failedInstallNames.contains(name) {
                installLog.append("✓ \(name) installed")
            }
            isInstallRunning = false
            installTask = nil
        }
    }

    /// Uninstalls one package — a destructive action, so the caller (the trash button's
    /// confirmation dialog) is responsible for confirming with the user first; this
    /// method itself just runs it and reports the outcome via `failedUninstallNames`.
    func uninstall(name: String, isCask: Bool) async {
        guard !uninstallingNames.contains(name) else { return }
        uninstallingNames.insert(name)
        failedUninstallNames.remove(name)
        defer { uninstallingNames.remove(name) }

        await logger.log("DashboardViewModel: uninstalling \(name)")
        do {
            try await service.uninstallPackage(name, isCask: isCask) { _ in }
            await refreshInstalled()
        } catch {
            failedUninstallNames.insert(name)
            await logger.log("DashboardViewModel: uninstall \(name) failed — \(error.localizedDescription)", .error)
        }
    }

    /// Kicks off a cancelable pack install — same task-ownership pattern as
    /// `MenuBarViewModel.upgradeAll()`/`cancelUpgrade()`, so there's always a real way
    /// out of the install-log sheet instead of it being stuck open until every package
    /// finishes on its own.
    func installPack(_ pack: InstallPack) {
        guard !isInstalling else { return }
        // Set synchronously, not inside the Task body — the sheet is bound to
        // `isInstalling`, so it must flip true the instant this is called rather than
        // waiting for the launched Task to get its first scheduling slot.
        isInstalling = true
        isInstallRunning = true
        installLog = []
        installTask = Task { await performInstallPack(pack) }
    }

    /// Stops the in-flight install (if any) but leaves the sheet showing whatever the
    /// log ended on — the sheet's own Cancel button while running. Closing the sheet
    /// itself is a separate, explicit step (`dismissInstallSheet()`), so the user
    /// always gets to see the final result instead of it vanishing the instant the
    /// process is killed.
    func cancelInstall() {
        installTask?.cancel()
        installTask = nil
        isInstallRunning = false
    }

    /// Closes the install-progress sheet — called once the user has actually looked at
    /// the result (the sheet's Done button), or from Esc/click-outside, in which case
    /// it also stops whatever's still running rather than leaving it detached from any UI.
    func dismissInstallSheet() {
        if isInstallRunning { cancelInstall() }
        isInstalling = false
    }

    private func performInstallPack(_ pack: InstallPack) async {
        defer {
            isInstallRunning = false
            installTask = nil
        }

        for name in pack.formulae {
            guard !Task.isCancelled else { return }
            await install(name: name, isCask: false)
        }
        for name in pack.casks {
            guard !Task.isCancelled else { return }
            await install(name: name, isCask: true)
        }

        let packageNames = pack.formulae + pack.casks
        let total = packageNames.count
        let failed = packageNames.filter { failedInstallNames.contains($0) }.count
        installLog.append(failed == 0
            ? "✓ Installed \(total)/\(total) packages"
            : "⚠ Installed \(total - failed)/\(total) packages — \(failed) failed"
        )
    }

    // MARK: - Search

    /// Called on every keystroke in the sidebar's search field. Debounces so typing
    /// doesn't spawn a `brew search` subprocess per character, and cancels any
    /// in-flight lookup that a newer keystroke has already made stale. Fills
    /// `searchResults`, shown live in the detail pane as the user types.
    func updateSearch(for query: String) {
        searchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Reset in full, not just the results — leaving a cancelled lookup's
            // `isSearching = true` behind here got stuck on: its own Task returns
            // early on cancellation, before ever reaching the line that clears it.
            searchTask?.cancel()
            searchTask = nil
            isSearching = false
            searchResults = []
            return
        }
        isSearching = true
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.performSearch(trimmed)
        }
    }

    /// Runs the full search immediately (no debounce) — used when the user presses
    /// Return, so results reflect that exact query right away instead of waiting on
    /// whatever debounced lookup is already in flight.
    func commitSearch(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        let task = Task { await self.performSearch(trimmed) }
        searchTask = task
        await task.value
    }

    /// Writes `searchResults` only if nothing newer has superseded this search —
    /// shared by the debounced (`updateSearch`) and immediate (`commitSearch`, on
    /// Return) paths so whichever one is slower can never clobber the other's fresher
    /// results. Before this, `commitSearch` ran as its own untracked `Task`: pressing
    /// Return then typing one more character could let the (slower) Return-triggered
    /// search land after the newer debounced one and silently overwrite it with stale
    /// results.
    private func performSearch(_ query: String) async {
        let results = await searchLogged(query)
        guard !Task.isCancelled else { return }
        searchResults = results
        isSearching = false
    }

    private func searchLogged(_ query: String) async -> [SearchResult] {
        do {
            return try await service.searchPackages(query)
        } catch {
            await logger.log("DashboardViewModel: searchPackages(\(query)) failed — \(error.localizedDescription)", .error)
            return []
        }
    }

    // MARK: - Package detail

    /// Opens the detail sheet for a package and kicks off its (cached, single-package)
    /// fetch. Guards against a stale response landing after the user has already
    /// switched to a different package's sheet.
    ///
    /// `tap`, when known, is checked against `officialTapNames` before hitting
    /// formulae.brew.sh: that API only indexes homebrew/core and homebrew/cask, so
    /// looking up a third-party package by its bare name there can silently return an
    /// unrelated *official* package that happens to share the same name (e.g. a custom
    /// cask "orca" colliding with Homebrew's own deprecated "orca" cask). For a known
    /// non-official tap, the sheet shows name + install command only — real data
    /// formulae.brew.sh doesn't have, not a failed fetch.
    func selectPackage(name: String, isCask: Bool, tap: String? = nil) {
        let target = PackageDetailTarget(name: name, isCask: isCask)
        selectedPackageDetailTarget = target
        isLoadingPackageDetail = true

        guard tap == nil || Self.officialTapNames.contains(tap!) else {
            packageDetail = PackageDetail(
                name: name, isCask: isCask, desc: nil, homepage: nil, version: nil,
                requirements: [], deprecated: false, deprecationReason: nil,
                disabled: false, disableDate: nil,
                installs30d: nil, installs90d: nil, installs365d: nil
            )
            isLoadingPackageDetail = false
            return
        }

        packageDetail = nil
        Task { [weak self] in
            guard let self else { return }
            let detail = try? await self.apiClient.fetchPackageDetail(name: name, isCask: isCask)
            guard self.selectedPackageDetailTarget == target else { return }
            self.packageDetail = detail
            self.isLoadingPackageDetail = false
        }
    }

    // MARK: - Private

    private static func loadBundledInstallPacks() -> [InstallPack] {
        guard let url = AppBundle.resources.url(forResource: "InstallPacks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let packs = try? JSONDecoder().decode([InstallPack].self, from: data)
        else { return [] }
        return packs
    }

    private static func loadBundledRecommendedTaps() -> [RecommendedTap] {
        guard let url = AppBundle.resources.url(forResource: "RecommendedTaps", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let taps = try? JSONDecoder().decode([RecommendedTap].self, from: data)
        else { return [] }
        return taps
    }
}
