import BrewCore
import Foundation

/// The package a detail page shows. `tap`, when known, keeps a third-party package from being
/// looked up as the official one that shares its name (see `selectPackage`).
struct PackageDetailTarget: Identifiable, Hashable {
    let name: String
    let isCask: Bool
    var tap: String?

    var id: String {
        "\(name)-\(isCask)"
    }
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

/// A failed action with nowhere of its own to show the reason (no row, no sheet) — presented as
/// one alert in `DashboardView`. `details` is what "Copy error" puts on the clipboard.
struct ActionFailure: Equatable {
    let title: String
    let message: String
    let details: String

    init(title: String, error: Error) {
        self.title = title
        message = error.localizedDescription
        details = (error as? BrewError)?.details ?? error.localizedDescription
    }
}

@MainActor
@Observable
final class DashboardViewModel {
    private let service: any BrewServicing
    private let apiClient: any HomebrewAPIServicing
    private let logger: BrewLogger
    /// Installed packages, taps and the outdated list live here, shared with the menu bar — this
    /// view model only adds what the Dashboard's screens need on top.
    let store: BrewStore

    /// True for the duration of the first `load()` — lets Home/Installed show a
    /// spinner instead of their empty state while waiting on `waitUntilConfigured()`
    /// (which can otherwise take a moment right after launch), so "0 packages" never
    /// briefly reads as "nothing installed" on a machine that has plenty.
    private(set) var isLoading = false
    var installedPackages: [InstalledPackage] {
        store.installed
    }

    var taps: [Tap] {
        store.taps
    }

    /// Why Homebrew couldn't be reached at all on `load()` — see `installedError`.
    private var configureError: String?
    /// Why the last `brew list` failed, or nil. Lets the Installed screen say "couldn't
    /// load" instead of showing an empty list that looks like a real result.
    var installedError: String? {
        store.failures[.installed] ?? configureError
    }

    private(set) var trendingError: String?
    private(set) var trendingFormulae: [TrendingPackage] = []
    private(set) var trendingCasks: [TrendingPackage] = []
    private(set) var installPacks: [InstallPack] = []
    private(set) var cacheEntries: [CacheEntry] = []
    private(set) var isLoadingCache = false
    private(set) var cacheError: String?
    /// Deleting individually (not `installingNames`-style, since cache rows aren't
    /// packages) — lets a row show its own spinner instead of the whole list
    /// appearing to hang while one file is removed.
    private(set) var deletingCacheEntryIDs: Set<String> = []
    var totalCacheBytes: Int64 {
        cacheEntries.reduce(0) { $0 + $1.sizeBytes }
    }

    private(set) var packageDiskUsage: [PackageDiskUsage] = []
    private(set) var isLoadingDiskUsage = false
    private(set) var diskUsageError: String?
    private(set) var installingNames: Set<String> = []
    /// The real reason each failed install failed (e.g. Homebrew's own "there's
    /// already an App at /Applications/X.app" conflict message) — every row showing
    /// "Install failed" used to hardcode the same generic "check the name and try
    /// again" regardless of cause, hiding an error that was often specific and
    /// actionable (name typo vs. an existing app in the way vs. a network failure
    /// are very different problems with very different fixes).
    private(set) var installErrors: [String: String] = [:]
    /// Derived from `installErrors` rather than tracked separately — the two were
    /// always mutated in lockstep, so keeping a second `Set` around was just a second
    /// place the same fact could drift out of sync.
    var failedInstallNames: Set<String> {
        Set(installErrors.keys)
    }

    /// Set by an action whose failure has no row or sheet to land on (removing a tap). Cleared when
    /// its alert is dismissed.
    var actionFailure: ActionFailure?

    private(set) var installLog: [String] = []
    /// The packages of the install session the sheet is showing. The sheet reports failures for
    /// these only: `installErrors` also keeps earlier attempts, which made a clean install look
    /// failed whenever some unrelated package had failed before it.
    private(set) var installSessionNames: [String] = []
    var installSessionFailures: [(name: String, message: String)] {
        installSessionNames.compactMap { name in installErrors[name].map { (name, $0) } }
    }

    /// Bumped by every new install session. A cancelled session's task keeps running until brew
    /// has really exited; by then the user may have started another, and the old task must not
    /// write into its log or reset its running state.
    @ObservationIgnored private var installSession = 0
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
    /// True from Cancel until brew has really stopped (it gets a moment to exit cleanly). The sheet
    /// says so instead of showing "Done" while Homebrew is still busy.
    private(set) var isCancellingInstall = false
    /// Whether the session on screen was stopped by Cancel. A cancel records no failure (it's the
    /// user's choice), so without this the sheet ended on a green "Done".
    private(set) var installWasCancelled = false

    /// What "Ask AI" quotes for a failed install: the command, brew's reason, and the end of the log
    /// (where the reason usually is, after the downloads and dependencies).
    func installFailureReport(name: String) -> String {
        let reason = installErrors[name] ?? ""
        let tail = installLog.suffix(30).joined(separator: "\n")
        return "brew install \(name)\n\n\(reason)\n\n\(tail)"
    }

    /// Where the install sheet's session stands — what its title, icon and announcement follow.
    enum InstallPhase: Equatable {
        case running, cancelling, cancelled, failed, done
    }

    var installPhase: InstallPhase {
        if isInstallRunning { return .running }
        if isCancellingInstall { return .cancelling }
        if installWasCancelled { return .cancelled }
        return installSessionFailures.isEmpty ? .done : .failed
    }

    /// The install sheet's progress bar value (0...1) — real curl percentages when
    /// they're flowing, blended with a time-based simulation the rest of the time
    /// (see `startProgressSimulation()`) so the bar is always visibly moving instead
    /// of sitting frozen during dependency resolution or between curl's updates.
    /// `nil` before an install has started.
    private(set) var installProgress: Double?
    /// True when the most recently appended `installLog` entry was itself a progress
    /// update (as opposed to a real completed line from brew) — lets the next update
    /// replace it in place instead of piling up one entry per repaint, same as a real
    /// terminal overwriting its own progress meter in place.
    @ObservationIgnored private var installLogLastIsProgress = false
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var progressSimulationTask: Task<Void, Never>?

    private(set) var uninstallingNames: Set<String> = []
    /// The real reason each failed uninstall failed (e.g. Homebrew refusing because
    /// another installed package still depends on it) — same shape as `installErrors`,
    /// translated through `friendlyUninstallError` for the one failure mode common
    /// enough to be worth a plain-language explanation instead of raw Homebrew output.
    private(set) var uninstallErrors: [String: String] = [:]
    /// Derived from `uninstallErrors` — same reasoning as `failedInstallNames`.
    var failedUninstallNames: Set<String> {
        Set(uninstallErrors.keys)
    }

    /// Set alongside `uninstallErrors[name]` on a failed uninstall — drives a one-shot
    /// `.alert()` in `DashboardView` so the failure (and, for the common "something else
    /// depends on it" case, the actionable fix) is impossible to miss, instead of sitting
    /// only in a tooltip on a small trash icon the user has to go hover to find. Cleared
    /// once the alert's been dismissed; `uninstallErrors[name]` itself stays set so the
    /// row's trash icon/tooltip keep reflecting the failure afterward too.
    var uninstallFailureAlertName: String?

    var searchQuery: String = ""
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching: Bool = false
    /// True while results are already showing and brew is still looking for more.
    private(set) var isRefiningSearch = false
    /// Why the last search failed, or nil. Lets the results screen say "search failed"
    /// instead of "No results", which would read as "nothing matches".
    private(set) var searchError: String?
    private var searchTask: Task<Void, Never>?

    /// The package whose detail is loaded (or loading) — the detail page's data, not what presents it.
    private(set) var selectedPackageDetailTarget: PackageDetailTarget?
    private(set) var packageDetail: PackageDetail?
    private(set) var isLoadingPackageDetail = false

    /// Unlike `packageDetail` above (fetched from formulae.brew.sh for every selected
    /// package, installed or not), this comes from the local `brew list` and only makes
    /// sense for one already installed — loaded on demand (`loadPackageFiles`), not
    /// automatically on every `selectPackage`, since most detail-sheet opens never open
    /// this section.
    private(set) var packageFiles: [String]?
    private(set) var isLoadingPackageFiles = false
    private(set) var packageFilesError: String?

    private(set) var isAddingTap = false
    private(set) var addTapError: String?
    /// The tap currently being added, and the one whose add failed — so a spinner or
    /// error lands on that card, not on every card.
    private(set) var addingTapName: String?
    private(set) var addTapFailedName: String?
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
        installedPackagesCache: InstalledPackagesCache = InstalledPackagesCache(),
        store: BrewStore? = nil,
        logger: BrewLogger = .shared
    ) {
        self.service = service
        self.apiClient = apiClient
        self.store = store ?? BrewStore(service: service, installedCache: installedPackagesCache)
        self.logger = logger
        installPacks = Self.loadBundledInstallPacks()
    }

    // MARK: - Loading

    func load() async {
        await logger.log("DashboardViewModel: load() started")
        // Paint the last-known installed list instantly (if any) instead of blocking
        // every launch on a fresh `brew info --json=v2 --installed` subprocess spawn —
        // see InstalledPackagesCache. Only a genuine first-ever launch (nothing cached
        // yet) still shows the spinner below while the real fetch completes.
        let hadCache = await store.primeInstalledFromCache()
        // Not awaited: the catalog paints from disk, and a download behind it mustn't hold up the
        // installed list.
        Task { await store.loadCatalog() }
        // load() can run before BrewService.bootstrap() (kicked off separately from
        // BrewMenuApp.init()) has finished — e.g. the Dashboard window opens moments
        // after launch. Waiting on the real signal here (resumed the instant
        // bootstrap() configures the resolver) replaces a blind fixed-delay retry loop.
        isLoading = !hadCache
        defer { isLoading = false }
        do {
            try await service.waitUntilConfigured()
            configureError = nil
            await refreshInstalled()
            await logger
                .log("DashboardViewModel: load() got \(installedPackages.count) installed packages, \(taps.count) taps")
        } catch {
            // Bootstrap failed (e.g. Homebrew not found) — degrade to the existing
            // empty installedPackages/taps rather than hanging in isLoading forever.
            // Trending below is independent of local Homebrew and still worth loading.
            // The reason goes to `installedError`: an empty Installed screen would read as
            // "nothing installed".
            configureError = error.localizedDescription
            await logger.log(
                "DashboardViewModel: load() — Homebrew isn't configured (\(error.localizedDescription))",
                .error
            )
        }

        await loadTrending()
    }

    /// Network-backed and independent of local Homebrew, so it never blocks Home from
    /// rendering. A failure keeps whatever was loaded before and surfaces `trendingError`
    /// (with a Retry) instead of quietly hiding the section.
    func loadTrending() async {
        // Two independent requests: no reason to wait for one before starting the other.
        async let formulae = trendingResult(casks: false)
        async let casks = trendingResult(casks: true)
        var failure: String?
        switch await formulae {
        case let .success(packages): trendingFormulae = packages
        case let .failure(error): failure = error.localizedDescription
        }
        switch await casks {
        case let .success(packages): trendingCasks = packages
        case let .failure(error): failure = error.localizedDescription
        }
        trendingError = failure
        trending = (trendingFormulae + trendingCasks).sorted { $0.installCount > $1.installCount }
        installCounts = Dictionary(
            trending.map { (Self.popularityKey($0.name, isCask: $0.isCask), $0.installCount) },
            uniquingKeysWith: max
        )
    }

    private func trendingResult(casks: Bool) async -> Result<[TrendingPackage], Error> {
        do {
            return try await .success(casks ? apiClient.fetchTrendingCasks() : apiClient.fetchTrendingFormulae())
        } catch {
            return .failure(error)
        }
    }

    /// A failed `brew list` keeps what's already on screen (and on disk) — the failure is
    /// surfaced via `installedError` instead.
    func refreshInstalled() async {
        await store.refresh([.installed, .taps])
    }

    /// Set synchronously by `refresh()` (the guard against a second click). `isRefreshing` adds
    /// whatever else is refreshing the same data — the menu bar's Refresh, the timer, `load()`.
    private var isRefreshingHere = false
    var isRefreshing: Bool {
        isRefreshingHere || store.isCheckingForUpdates || store.isRefreshing(.installed)
    }

    /// Manual refresh — the toolbar button in `DashboardView`. Re-checks what's actually
    /// installed (in case something changed outside the app, e.g. running the
    /// `--ignore-dependencies` command a failed-uninstall alert suggested) and clears
    /// every stale `installErrors`/`uninstallErrors` entry, so a failed row doesn't stay
    /// red for the rest of the session just because nobody happened to retry that exact
    /// package. A permanent failure (like a formula with no bottle for this platform)
    /// will simply turn red again the next time it's retried — this only dismisses the
    /// old attempt, it doesn't pretend anything succeeded.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshingHere = true
        defer { isRefreshingHere = false }
        // `brew update` can take a while; the Outdated card picks the result up from the store.
        Task { await store.checkForUpdates() }
        await refreshInstalled()
        installErrors = [:]
        uninstallErrors = [:]
    }

    // MARK: - Ecosystems

    /// Taps with at least one installed package — the ecosystems overview's rows.
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

    var installedCount: Int {
        installedPackages.count
    }

    /// The same number the menu bar icon and the Outdated Packages section show — `brew outdated`'s
    /// list, not `installedPackages.filter(\.outdated)`: that flag comes from `brew info`, fetched on
    /// its own schedule, and can disagree with it.
    var outdatedInstalledCount: Int {
        store.outdated.count
    }

    /// Sorted here, not by each of the 4 callers separately — they all applied the
    /// identical `.sorted { $0.name < $1.name }` after calling this, duplicated instead
    /// of shared (not `InstalledView.filteredPackages`'s sort, a different, view-local
    /// filter pipeline over all installed packages, not this tap-scoped one).
    func packages(in tap: Tap) -> [InstalledPackage] {
        (store.installedByTap[tap.name] ?? []).sorted { $0.name < $1.name }
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
        addingTapName = trimmed
        addTapFailedName = nil
        defer {
            isAddingTap = false
            addingTapName = nil
        }
        do {
            try await service.addTap(trimmed, onLine: { _ in })
            await store.refresh(after: .tap)
            return true
        } catch {
            addTapError = error.localizedDescription
            addTapFailedName = trimmed
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
        guard case let .packageCandidate(name) = AddInputKind.classify(AddInputKind.sanitize(raw)) else { return }
        resolvedPackage = nil
        resolvePackageError = nil
        isResolvingPackage = true
        defer { isResolvingPackage = false }
        do {
            if let resolved = try await service.resolvePackage(name) {
                resolvedPackage = resolved
            } else {
                resolvePackageError =
                    L(
                        "Couldn't find a formula or cask named \"\(name)\". Check the spelling, or use the full name (user/repo/name) if it's from a tap you haven't added yet."
                    )
            }
        } catch {
            resolvePackageError = error.localizedDescription
            await logger.log(
                "DashboardViewModel: resolvePackage \(name) failed — \(error.localizedDescription)",
                .error
            )
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
            // What this view model remembered about the tap goes with it: re-adding it later
            // showed the old package list.
            tapPackages[name] = nil
            tapPackagesError[name] = nil
            autoRetriedTaps.remove(name)
            await store.refresh(after: .untap)
        } catch is CancellationError {
            // Not a failure.
        } catch {
            actionFailure = ActionFailure(title: L("Couldn't remove \(name)"), error: error)
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
            await logger.log(
                "DashboardViewModel: loadTapPackages \(tap) failed — \(error.localizedDescription)",
                .error
            )
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

    /// `brew search` qualifies a match's name with its tap (e.g. `dotfn/tap/lumus-control`)
    /// whenever it's outside the default taps, while `InstalledPackage.name` is always the bare
    /// short name — so both are looked up (see `BrewStore.installedPackage(named:)`), or an
    /// installed package from a third-party tap looked available to install again.
    func isInstalled(_ name: String) -> Bool {
        store.installedPackage(named: name) != nil
    }

    func isTapped(_ tapName: String) -> Bool {
        taps.contains { $0.name == tapName }
    }

    /// Whether an installed package needs updating — Trending/Recommended/Search rows
    /// otherwise only ever showed a plain "Installed" checkmark even when the package
    /// was actually out of date, unlike `InstalledPackageRow`'s "Outdated" badge.
    func isOutdated(_ name: String) -> Bool {
        store.isOutdated(name)
    }

    /// Whether an installed package came from an official tap (homebrew/core/cask) —
    /// used to flag outdated packages from third-party taps, which didn't go through
    /// the same review. `true` (don't flag) if the package isn't found at all, since a
    /// lookup failure isn't evidence the origin is actually third-party.
    func isOfficialOrigin(_ name: String) -> Bool {
        guard let package = store.installedPackage(named: name) else { return true }
        return Tap(name: package.tap).isOfficial
    }

    /// Other installed formulae that actually link against `name` at runtime — a
    /// heuristic "what might this break" signal shown before uninstalling, not a
    /// guarantee (see `InstalledPackage.runtimeDependencyNames`). A fresh scan over
    /// `installedPackages` rather than a prebuilt index: this only runs once, right
    /// when the user taps the trash button on a few hundred installed packages at
    /// most — not worth the bookkeeping a reverse index would add to every install/
    /// uninstall/refresh.
    func installedDependents(of name: String) -> [String] {
        installedPackages
            .filter { $0.runtimeDependencyNames.contains(name) }
            .map(\.name)
            .sorted()
    }

    // MARK: - Trending

    /// Trending formulae + casks merged and ranked by install count — what `installCounts` is
    /// built from.
    private(set) var trending: [TrendingPackage] = []

    // MARK: - Popularity

    /// 30-day installs per package, from the same analytics as Trending — what the catalog's lists
    /// and search results are ranked by.
    private var installCounts: [String: Int] = [:] {
        didSet { installCountsVersion += 1 }
    }

    private var installCountsVersion = 0

    private nonisolated static func popularityKey(_ name: String, isCask: Bool) -> String {
        "\(isCask ? "cask" : "formula"):\(name)"
    }

    func installCount(of package: CatalogPackage) -> Int {
        installCounts[Self.popularityKey(package.name, isCask: package.isCask)] ?? 0
    }

    // MARK: - Catalog lists

    /// One sorted list of apps or formulae, for one catalog and one set of install counts.
    struct RankingKey: Hashable {
        let apps: Bool
        let byPopularity: Bool
        let catalogVersion: Int
        let countsVersion: Int
    }

    /// Sorted lists kept across visits: thousands of packages shouldn't be re-sorted every time
    /// the Apps or Command Line section is opened.
    private var rankings: [RankingKey: [CatalogPackage]] = [:]

    func rankingKey(apps: Bool, byPopularity: Bool) -> RankingKey {
        RankingKey(
            apps: apps,
            byPopularity: byPopularity,
            catalogVersion: store.catalogVersion,
            countsVersion: installCountsVersion
        )
    }

    func ranking(for key: RankingKey) -> [CatalogPackage]? {
        rankings[key]
    }

    /// Sorts off the main actor, from a copy of the counts; a list for an older catalog or older
    /// counts is dropped when a newer one lands.
    func rank(_ key: RankingKey) async {
        guard rankings[key] == nil, let catalog = store.catalog else { return }
        let source = key.apps ? catalog.apps : catalog.formulae
        let sorted = key.byPopularity ? await Self.byInstalls(source, counts: installCounts) : source
        rankings = rankings.filter {
            $0.key.catalogVersion == key.catalogVersion && $0.key.countsVersion == key.countsVersion
        }
        rankings[key] = sorted
    }

    @concurrent
    private static func byInstalls(_ packages: [CatalogPackage], counts: [String: Int]) async -> [CatalogPackage] {
        packages
            .map { (package: $0, installs: counts[popularityKey($0.name, isCask: $0.isCask)] ?? 0) }
            .sorted { $0.installs != $1.installs ? $0.installs > $1.installs : $0.package.name < $1.package.name }
            .map(\.package)
    }

    // MARK: - Deprecation lookups

    /// Deprecated/disabled status for a package not sourced from `brew info --json=v2
    /// --installed` (i.e. not yet installed) — `brew search` results carry only a name,
    /// so Search Results rows fetch this lazily, same pattern as Recommended's
    /// description lookup. Cached 6h by the same on-disk cache as the detail sheet.
    func deprecationStatus(for name: String, isCask: Bool) async -> (deprecated: Bool, disabled: Bool) {
        if let catalogEntry = store.catalogPackage(named: name, isCask: isCask) {
            return (catalogEntry.deprecated, catalogEntry.disabled)
        }
        // formulae.brew.sh only knows homebrew/core and homebrew/cask: asking it about
        // `user/repo/name` is a 404 every time the row scrolls in.
        guard name.split(separator: "/").count < 3 else { return (false, false) }
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
        await install(name: name, isCask: isCask, partOfPack: false)
    }

    /// A pack refreshes only the installed list after each package (so its rows turn installed as
    /// they finish) and everything an install touches once, at the end.
    private func install(name: String, isCask: Bool, partOfPack: Bool) async {
        guard !installingNames.contains(name) else { return }
        installingNames.insert(name)
        installErrors[name] = nil
        defer { installingNames.remove(name) }

        await logger.log("DashboardViewModel: installing \(name)")
        // Lines and progress share one ordered stream: progress replaces the last entry
        // only if no line arrived after it, so their relative order matters.
        let session = installSession
        let output = makeOrderedStream { [weak self] (event: CommandOutputEvent) in
            guard let self, installSession == session else { return }
            switch event {
            case let .line(line): appendInstallLine(line)
            case let .progress(text): appendInstallProgress(text)
            }
        }
        defer { output.finish() }
        do {
            try await service
                .installPackage(name, isCask: isCask) { output.send(.line($0)) } onProgress: {
                    output.send(.progress($0))
                }
            if partOfPack {
                await store.refresh([.installed])
            } else {
                await store.refresh(after: .install)
            }
        } catch is CancellationError {
            // Cancelling is the user's choice, not a failure — leave the row unmarked
            // and the summary's failed count untouched.
            if installSession == session {
                appendInstallLine(L("\(name) cancelled"))
            }
            await logger.log("DashboardViewModel: install \(name) cancelled")
        } catch {
            installErrors[name] = error.localizedDescription
            if installSession == session {
                appendInstallLine("✗ " + L("\(name) failed — \(error.localizedDescription)"))
            }
            await logger.log("DashboardViewModel: install \(name) failed — \(error.localizedDescription)", .error)
        }
    }

    /// A real completed line from brew — always appended, and it always ends any
    /// in-place progress-update streak (see `appendInstallProgress`).
    private func appendInstallLine(_ line: String) {
        installLog.append(line)
        installLogLastIsProgress = false
    }

    /// A `\r`-terminated in-place update (a download percentage, typically). Parsed
    /// for a trailing "NN.N%" to drive `installProgress`; shown in the log by
    /// replacing the previous progress entry rather than appending a new one each
    /// time — curl repaints this dozens of times a second, and piling up one log
    /// line per repaint would make "Show more" useless.
    private func appendInstallProgress(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let percent = CommandProgress.parsePercent(from: trimmed) {
            // Monotonic — never let the bar visibly step backward. curl's own
            // meter is already increasing, but a mid-download retry/redirect can
            // restart it near 0%, which would otherwise read as the install
            // undoing itself instead of one continuous download.
            installProgress = max(installProgress ?? 0, percent)
        }
        if installLogLastIsProgress, !installLog.isEmpty {
            installLog[installLog.count - 1] = trimmed
        } else {
            installLog.append(trimmed)
            installLogLastIsProgress = true
        }
    }

    /// Ticks `installProgress` upward on a clock instead of waiting on curl — brew
    /// spends real, sometimes lengthy stretches (tapping, dependency resolution,
    /// "Fetching downloads for: …") reporting no percentage at all, which otherwise
    /// left the bar sitting dead at 0% looking stuck. Capped well under 100%
    /// (`CommandProgress.simulated`'s default `cap`) so simulation alone can never
    /// claim the install is done — only a real curl percentage crossing it (via the
    /// `max()` in `appendInstallProgress`) or the process actually finishing can do that.
    private func startProgressSimulation() {
        progressSimulationTask?.cancel()
        let start = Date()
        progressSimulationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                let simulated = CommandProgress.simulated(elapsedSeconds: elapsed)
                installProgress = max(installProgress ?? 0, simulated)
            }
        }
    }

    private func stopProgressSimulation() {
        progressSimulationTask?.cancel()
        progressSimulationTask = nil
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
        let session = beginInstallSession([name])
        installTask = Task {
            await syncDatabaseBeforeInstalling(session: session)
            if !Task.isCancelled { await install(name: name, isCask: isCask) }
            guard installSession == session else { return }
            isCancellingInstall = false
            // `install()` already appends a "✗ … failed" line on error — add the
            // matching success line here so a finished sheet always ends on an
            // explicit result instead of just trailing off after the last brew line.
            if !failedInstallNames.contains(name), !Task.isCancelled {
                appendInstallLine("✓ " + L("\(name) installed"))
            }
            isInstallRunning = false
            installTask = nil
            stopProgressSimulation()
        }
    }

    /// Installing from a stale database would install whatever version was current back then, so
    /// it's brought up to date first (see `BrewStore.syncDatabaseIfStale`), and the log says so.
    private func syncDatabaseBeforeInstalling(session: Int) async {
        await store.syncDatabaseIfStale {
            if installSession == session { appendInstallLine(L("Updating the package database…")) }
        }
    }

    /// Resets the sheet's state for a new run and returns its session number (see `installSession`).
    private func beginInstallSession(_ names: [String]) -> Int {
        installSession += 1
        installSessionNames = names
        isCancellingInstall = false
        installWasCancelled = false
        isInstalling = true
        isInstallRunning = true
        installLog = []
        installProgress = nil
        installLogLastIsProgress = false
        startProgressSimulation()
        return installSession
    }

    /// Uninstalls one package — a destructive action, so the caller (the trash button's
    /// confirmation dialog) is responsible for confirming with the user first; this
    /// method itself just runs it and reports the outcome via `uninstallErrors`.
    func uninstall(name: String, isCask: Bool) async {
        guard !uninstallingNames.contains(name) else { return }
        uninstallingNames.insert(name)
        uninstallErrors[name] = nil
        defer { uninstallingNames.remove(name) }

        await logger.log("DashboardViewModel: uninstalling \(name)")
        do {
            try await service.uninstallPackage(name, isCask: isCask) { _ in }
            packageDiskUsage.removeAll { $0.name == name && $0.isCask == isCask }
            await store.refresh(after: .uninstall)
        } catch {
            uninstallErrors[name] = Self.friendlyUninstallError(error, name: name)
            uninstallFailureAlertName = name
            await logger.log("DashboardViewModel: uninstall \(name) failed — \(error.localizedDescription)", .error)
        }
    }

    /// Translates Homebrew's raw uninstall failure into something a non-technical user
    /// can act on, for the one failure mode common enough to be worth it: refusing to
    /// remove a package because something else installed still depends on it (the
    /// overwhelming majority of real `uninstall` failures — confirmed against a real
    /// "Refusing to uninstall ... because it is required by ..." error). Without this,
    /// the trash icon just turned red with a generic "try again" tooltip that gave no
    /// indication anything was actually wrong with the *request* rather than the app.
    /// Anything else falls back to Homebrew's own message, same as `install()` does.
    private static func friendlyUninstallError(_ error: Error, name: String) -> String {
        if case let .commandFailed(_, stderr, _) = error as? BrewError, stderr.contains("Refusing to uninstall") {
            return L(
                "Another installed package still depends on \(name), so Homebrew won't remove it automatically. To force it anyway, run this in Terminal:\n\nbrew uninstall --ignore-dependencies \(name)"
            )
        }
        return error.localizedDescription
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
        let session = beginInstallSession(pack.formulae + pack.casks)
        installTask = Task { await performInstallPack(pack, session: session) }
    }

    /// Stops the in-flight install (if any) but leaves the sheet showing whatever the
    /// log ended on — the sheet's own Cancel button while running. Closing the sheet
    /// itself is a separate, explicit step (`dismissInstallSheet()`), so the user
    /// always gets to see the final result instead of it vanishing the instant the
    /// process is killed.
    func cancelInstall() {
        isCancellingInstall = installTask != nil
        if installTask != nil { installWasCancelled = true }
        installTask?.cancel()
        installTask = nil
        isInstallRunning = false
        stopProgressSimulation()
    }

    /// Closes the install-progress sheet — called once the user has actually looked at
    /// the result (the sheet's Done button), or from Esc/click-outside, in which case
    /// it also stops whatever's still running rather than leaving it detached from any UI.
    func dismissInstallSheet() {
        if isInstallRunning { cancelInstall() }
        isInstalling = false
    }

    private func performInstallPack(_ pack: InstallPack, session: Int) async {
        defer {
            if installSession == session {
                isCancellingInstall = false
                isInstallRunning = false
                installTask = nil
                stopProgressSimulation()
            }
        }

        await syncDatabaseBeforeInstalling(session: session)
        for name in pack.formulae {
            guard !Task.isCancelled else { break }
            await install(name: name, isCask: false, partOfPack: true)
        }
        for name in pack.casks {
            guard !Task.isCancelled else { break }
            await install(name: name, isCask: true, partOfPack: true)
        }
        guard !Task.isCancelled else {
            // Whatever finished before the cancel is installed. Not awaited: the sheet's "stopping"
            // state shouldn't wait on it.
            Task { await store.refresh(after: .install) }
            return
        }
        await store.refresh(after: .install)

        let packageNames = pack.formulae + pack.casks
        let total = packageNames.count
        let failed = packageNames.count(where: { failedInstallNames.contains($0) })
        appendInstallLine(failed == 0
            ? "✓ " + L("Installed \(total)/\(total) packages")
            : "⚠ " + L("Installed \(total - failed)/\(total) packages — \(failed) failed"))
    }

    // MARK: - Cache

    /// Loads what's actually sitting in `brew --cache` right now — reads real files
    /// off disk each time (no cross-launch cache of its own), since this is exactly
    /// the "how much space is this really using" view where a stale answer defeats
    /// the point.
    func loadCacheEntries() async {
        isLoadingCache = true
        defer { isLoadingCache = false }
        do {
            cacheEntries = try await service.fetchCacheEntries()
            cacheError = nil
        } catch {
            cacheError = error.localizedDescription
        }
    }

    func deleteCacheEntry(_ entry: CacheEntry) async {
        guard !deletingCacheEntryIDs.contains(entry.id) else { return }
        deletingCacheEntryIDs.insert(entry.id)
        defer { deletingCacheEntryIDs.remove(entry.id) }
        do {
            try await service.deleteCacheEntry(entry)
            cacheEntries.removeAll { $0.id == entry.id }
        } catch {
            cacheError = error.localizedDescription
        }
    }

    /// Empties the whole cache directory — the "Clear Cache" toolbar action, behind
    /// its own confirmation in the UI since it can't be undone.
    func clearCache() async {
        isLoadingCache = true
        defer { isLoadingCache = false }
        do {
            try await service.clearCache()
            cacheEntries = []
            cacheError = nil
        } catch {
            cacheError = error.localizedDescription
        }
    }

    // MARK: - Disk Usage

    /// Real on-disk size of every installed package's Cellar/Caskroom directory —
    /// computed on demand (walking every package's directory tree isn't cheap enough
    /// to do on every `load()`), sorted biggest first since that's what actually
    /// matters for "what should I remove to free space."
    func loadDiskUsage() async {
        isLoadingDiskUsage = true
        defer { isLoadingDiskUsage = false }
        do {
            let targets = installedPackages.map { (name: $0.name, isCask: $0.isCask) }
            packageDiskUsage = try await service.fetchPackageDiskUsage(for: targets)
            diskUsageError = nil
        } catch {
            diskUsageError = error.localizedDescription
        }
    }

    /// The row leaves the list on success — `uninstall` drops it, wherever it was started from.
    func uninstallFromDiskUsage(_ entry: PackageDiskUsage) async {
        await uninstall(name: entry.name, isCask: entry.isCask)
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
            isRefiningSearch = false
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
        if let catalog = store.catalog {
            await performCatalogSearch(query, in: catalog)
            return
        }
        // First what Homebrew's name lists give at once, so results are on screen while brew is
        // still starting. brew's own answer then replaces it: it adds aliases and near-misses.
        let local = await (try? service.searchPackagesLocally(query)) ?? nil
        guard !Task.isCancelled else { return }
        if let local, !local.isEmpty {
            searchResults = local
            searchError = nil
            isSearching = false
            isRefiningSearch = true
        }
        // A superseded search leaves the flag to the one that replaced it.
        defer { if !Task.isCancelled { isRefiningSearch = false } }
        let results = await searchLogged(query, keepingOnFailure: local)
        guard !Task.isCancelled else { return }
        // Local matches lead, in the order already shown; brew's extras go after them, so
        // nothing the user may be about to click moves.
        let shown = Set((local ?? []).map(\.id))
        searchResults = (local ?? []) + results.filter { !shown.contains($0.id) }
        isSearching = false
    }

    /// With the catalog loaded, a search never starts brew: homebrew/core and homebrew/cask come
    /// from the catalog (names, aliases and descriptions), third-party taps from their folders on
    /// disk (see `LocalPackageIndex`), which is all `brew search` itself would look through.
    private func performCatalogSearch(_ query: String, in catalog: PackageCatalogIndex) async {
        let official = catalog.search(query) { installCount(of: $0) }
            .map { SearchResult(name: $0.name, isCask: $0.isCask) }
        let local = await (try? service.searchPackagesLocally(query)) ?? nil
        guard !Task.isCancelled else { return }
        let thirdParty = (local ?? []).filter { $0.name.split(separator: "/").count == 3 }
        searchResults = official + thirdParty
        searchError = nil
        isSearching = false
        isRefiningSearch = false
    }

    /// `local` are matches already on screen: with those, a failed brew search isn't worth an
    /// error state — the user has results.
    private func searchLogged(_ query: String, keepingOnFailure local: [SearchResult]?) async -> [SearchResult] {
        do {
            let results = try await service.searchPackages(query)
            searchError = nil
            return results
        } catch is CancellationError {
            return []
        } catch {
            if local?.isEmpty != false { searchError = error.localizedDescription }
            await logger.log(
                "DashboardViewModel: searchPackages(\(query)) failed — \(error.localizedDescription)",
                .error
            )
            return []
        }
    }

    // MARK: - Package detail

    /// The page for a package known only by its name, as `brew doctor` names them. An installed one
    /// brings its kind and tap; anything else is taken for a formula, the only kind doctor names.
    func detailTarget(forPackageNamed name: String) -> PackageDetailTarget {
        let installed = store.installedPackage(named: name)
        return PackageDetailTarget(name: name, isCask: installed?.isCask ?? false, tap: installed?.tap)
    }

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
        let target = PackageDetailTarget(name: name, isCask: isCask, tap: tap)
        selectedPackageDetailTarget = target
        isLoadingPackageDetail = true
        // A new sheet, so any files loaded for whatever package was selected before
        // this one don't flash on screen for the new target until loadPackageFiles
        // is called for it (if it ever is — most opens never request this section).
        packageFiles = nil
        packageFilesError = nil
        isLoadingPackageFiles = false

        guard tap.map({ Self.officialTapNames.contains($0) }) ?? true else {
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
            let detail = try? await apiClient.fetchPackageDetail(name: name, isCask: isCask)
            guard selectedPackageDetailTarget == target else { return }
            packageDetail = detail
            isLoadingPackageDetail = false
        }
    }

    /// Fetches the real list of files this installed package put on disk — called when
    /// the detail sheet's Files section is actually opened (`PackageDetailView`), not
    /// automatically on `selectPackage`. Guards against a stale response landing after
    /// the user already moved on to a different package's sheet, same as `selectPackage`.
    func loadPackageFiles(name: String, isCask: Bool) {
        guard let target = selectedPackageDetailTarget, target.name == name, target.isCask == isCask,
              packageFiles == nil, !isLoadingPackageFiles
        else { return }
        isLoadingPackageFiles = true
        packageFilesError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let files = try await service.fetchPackageFiles(name: name, isCask: isCask)
                guard selectedPackageDetailTarget == target else { return }
                packageFiles = files
            } catch {
                guard selectedPackageDetailTarget == target else { return }
                packageFilesError = error.localizedDescription
            }
            if selectedPackageDetailTarget == target { isLoadingPackageFiles = false }
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
}
