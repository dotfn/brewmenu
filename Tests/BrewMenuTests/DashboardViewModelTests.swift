import Testing
import Foundation
@testable import BrewMenu

// MARK: - Mocks

actor MockBrewServiceForDashboard: BrewServicing {
    var installedResponse: [InstalledPackage] = []
    var tapsResponse: [Tap] = []
    var installError: Error? = nil
    private(set) var installCalls: [(name: String, isCask: Bool)] = []
    private(set) var fetchInstalledCallCount = 0

    /// Simulates `BrewService`/`EnvironmentResolver`'s real configured/not-configured
    /// state — `waitUntilConfigured()` suspends here exactly like the real actor until
    /// `markConfigured()` (the test's stand-in for `bootstrap()` completing) resumes it,
    /// or throws immediately/on resume if `markBootstrapFailed()` was called instead
    /// (the test's stand-in for `bootstrap()` failing, e.g. brew not found).
    private var configured = true
    private var bootstrapFailure: Error?
    private var configuredContinuations: [CheckedContinuation<Void, Never>] = []

    func setConfigured(_ value: Bool) { configured = value }
    func markConfigured() {
        configured = true
        bootstrapFailure = nil
        resumeWaiters()
    }
    func markBootstrapFailed(_ error: Error) {
        bootstrapFailure = error
        resumeWaiters()
    }
    private func resumeWaiters() {
        let waiters = configuredContinuations
        configuredContinuations.removeAll()
        waiters.forEach { $0.resume() }
    }
    func waitUntilConfigured() async throws {
        if configured { return }
        if let bootstrapFailure { throw bootstrapFailure }
        await withCheckedContinuation { configuredContinuations.append($0) }
        if let bootstrapFailure { throw bootstrapFailure }
    }

    func setInstalledResponse(_ packages: [InstalledPackage]) { installedResponse = packages }
    func setTapsResponse(_ taps: [Tap]) { tapsResponse = taps }
    func setInstallError(_ error: Error?) { installError = error }
    var installDelayNanoseconds: UInt64 = 0
    func setInstallDelay(_ nanoseconds: UInt64) { installDelayNanoseconds = nanoseconds }

    func bootstrap(customBrewPath: String?) async throws {}
    func fetchOutdated() async throws -> [OutdatedPackage] { [] }
    func fetchInstalledCasks() async throws -> [CaskEntry] { [] }

    func fetchInstalledPackages() async throws -> [InstalledPackage] {
        fetchInstalledCallCount += 1
        return installedResponse
    }

    func fetchTaps() async throws -> [Tap] { tapsResponse }

    var tapPackagesResponse: [String: [SearchResult]] = [:]
    var tapPackagesError: Error? = nil
    private(set) var fetchTapPackagesCalls: [String] = []
    func setTapPackagesResponse(_ tap: String, _ packages: [SearchResult]) { tapPackagesResponse[tap] = packages }
    func setTapPackagesError(_ error: Error?) { tapPackagesError = error }

    func fetchTapPackages(_ tap: String) async throws -> [SearchResult] {
        fetchTapPackagesCalls.append(tap)
        if let error = tapPackagesError { throw error }
        return tapPackagesResponse[tap] ?? []
    }

    var resolvePackageResponse: ResolvedPackage? = nil
    var resolvePackageError: Error? = nil
    private(set) var resolvePackageCalls: [String] = []
    func setResolvePackageResponse(_ resolved: ResolvedPackage?) { resolvePackageResponse = resolved }
    func setResolvePackageError(_ error: Error?) { resolvePackageError = error }

    func resolvePackage(_ name: String) async throws -> ResolvedPackage? {
        resolvePackageCalls.append(name)
        if let error = resolvePackageError { throw error }
        return resolvePackageResponse
    }

    var addTapError: Error? = nil
    private(set) var addTapCalls: [String] = []
    func setAddTapError(_ error: Error?) { addTapError = error }

    func addTap(_ name: String, onLine: @escaping @Sendable (String) -> Void) async throws {
        addTapCalls.append(name)
        if let error = addTapError { throw error }
        tapsResponse.append(Tap(name: name))
    }

    var removeTapError: Error? = nil
    private(set) var removeTapCalls: [String] = []
    func setRemoveTapError(_ error: Error?) { removeTapError = error }

    func removeTap(_ name: String) async throws {
        removeTapCalls.append(name)
        if let error = removeTapError { throw error }
        tapsResponse.removeAll { $0.name == name }
    }

    var searchResponse: [SearchResult] = []
    func setSearchResponse(_ results: [SearchResult]) { searchResponse = results }
    func searchPackages(_ query: String) async throws -> [SearchResult] { searchResponse }
    func fetchServices() async throws -> [ServiceEntry] { [] }
    func runDoctor() async throws -> [DoctorWarning] { [] }
    func runCleanupDryRun() async throws -> Int64 { 0 }
    func runCleanup(onLine: @escaping @Sendable (String) -> Void) async throws {}
    func runAutoremoveDryRun() async throws -> [String] { [] }
    func runAutoremove(onLine: @escaping @Sendable (String) -> Void) async throws {}
    func runUpdate() async throws {}
    func runUpgrade(_ name: String) async throws {}
    func runUpgradeAll(onLine: @escaping @Sendable (String) -> Void) async throws {}

    func installPackage(_ name: String, isCask: Bool, onLine: @escaping @Sendable (String) -> Void) async throws {
        installCalls.append((name, isCask))
        if installDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: installDelayNanoseconds)
            guard !Task.isCancelled else { throw CancellationError() }
        }
        if let error = installError { throw error }
        onLine("Installing \(name)...")
        // Simulate the package becoming installed so a post-install refresh reflects it.
        installedResponse.append(InstalledPackage(
            name: name, tap: isCask ? "homebrew/cask" : "homebrew/core",
            desc: nil, homepage: nil, version: "1.0.0",
            isCask: isCask, pinned: false, outdated: false, deprecated: false,
            deprecationReason: nil, disabled: false, disableReason: nil
        ))
    }

    var uninstallError: Error? = nil
    private(set) var uninstallCalls: [(name: String, isCask: Bool)] = []
    func setUninstallError(_ error: Error?) { uninstallError = error }

    func uninstallPackage(_ name: String, isCask: Bool, onLine: @escaping @Sendable (String) -> Void) async throws {
        uninstallCalls.append((name, isCask))
        if let error = uninstallError { throw error }
        onLine("Uninstalling \(name)...")
        installedResponse.removeAll { $0.name == name }
    }

    func startService(_ name: String) async throws {}
    func stopService(_ name: String) async throws {}
}

actor MockHomebrewAPIService: HomebrewAPIServicing {
    var trendingFormulaeResponse: [TrendingPackage] = []
    var trendingCasksResponse: [TrendingPackage] = []
    var trendingError: Error? = nil

    func setTrendingFormulae(_ packages: [TrendingPackage]) { trendingFormulaeResponse = packages }
    func setTrendingError(_ error: Error?) { trendingError = error }

    func fetchTrendingFormulae() async throws -> [TrendingPackage] {
        if let error = trendingError { throw error }
        return trendingFormulaeResponse
    }

    func fetchTrendingCasks() async throws -> [TrendingPackage] {
        if let error = trendingError { throw error }
        return trendingCasksResponse
    }

    func fetchDescription(name: String, isCask: Bool) async throws -> String? { nil }

    var packageDetailResponses: [String: PackageDetail] = [:]
    var packageDetailDelays: [String: UInt64] = [:]
    private(set) var fetchPackageDetailCallCount = 0
    func setPackageDetailResponse(_ detail: PackageDetail?, for name: String) { packageDetailResponses[name] = detail }
    func setPackageDetailDelay(_ nanoseconds: UInt64, for name: String) { packageDetailDelays[name] = nanoseconds }

    func fetchPackageDetail(name: String, isCask: Bool) async throws -> PackageDetail? {
        fetchPackageDetailCallCount += 1
        if let delay = packageDetailDelays[name] {
            try? await Task.sleep(nanoseconds: delay)
        }
        return packageDetailResponses[name]
    }
}

/// A fresh, isolated cache directory per call so tests never touch the real
/// Application Support folder or leak state between runs (same pattern as
/// HomebrewAPIClientTests' `makeIsolatedCache()`).
private func makeIsolatedInstalledPackagesCache() -> InstalledPackagesCache {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return InstalledPackagesCache(directory: dir)
}

// MARK: - Fixtures

private func pkg(
    _ name: String, tap: String, isCask: Bool = false, outdated: Bool = false, desc: String? = nil,
    deprecated: Bool = false, disabled: Bool = false
) -> InstalledPackage {
    InstalledPackage(
        name: name, tap: tap, desc: desc, homepage: nil, version: "1.0.0",
        isCask: isCask, pinned: false, outdated: outdated, deprecated: deprecated,
        deprecationReason: nil, disabled: disabled, disableReason: nil
    )
}

// MARK: - Tests

@Suite("DashboardViewModel")
@MainActor
struct DashboardViewModelTests {

    // Regression: loadBundledInstallPacks() swallows JSON decode failures into an
    // empty array (`try?` — no error surfaced anywhere), so a typo in
    // InstallPacks.json would otherwise silently ship zero packs with no test noticing.
    // Reads the file directly by its on-disk repo path (via #filePath) rather than
    // through DashboardViewModel/AppBundle — the SPM resource bundle those resolve
    // (`Bundle.main`-relative) isn't reachable from a `swift test` process, so routing
    // through them here would just swap "silently empty in prod" for "silently empty
    // in tests" without ever validating the actual shipped JSON.
    @Test("InstallPacks.json decodifica sin errores, sin ids duplicados, y con packages no vacíos")
    func bundledInstallPacksJSONDecodesCorrectly() throws {
        let jsonURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DashboardViewModelTests.swift -> BrewMenuTests/
            .deletingLastPathComponent()  // -> Tests/
            .deletingLastPathComponent()  // -> repo root
            .appendingPathComponent("Sources/Resources/InstallPacks.json")
        let data = try Data(contentsOf: jsonURL)
        let packs = try JSONDecoder().decode([InstallPack].self, from: data)

        #expect(!packs.isEmpty)
        let ids = Set(packs.map(\.id))
        #expect(ids.count == packs.count)  // no duplicate ids
        #expect(ids.contains("ai-dev-tools"))
        #expect(ids.contains("chefs-suggestion"))
        for pack in packs {
            #expect(pack.packageCount > 0, "\(pack.id) has no formulae/casks")
        }
    }

    // Same reasoning/workaround as bundledInstallPacksJSONDecodesCorrectly above — reads
    // the file directly by its on-disk repo path rather than through
    // DashboardViewModel/AppBundle, which isn't reachable from `swift test`.
    @Test("RecommendedTaps.json decodifica sin errores, sin ids/taps duplicados, y con notablePackages no vacío")
    func bundledRecommendedTapsJSONDecodesCorrectly() throws {
        let jsonURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DashboardViewModelTests.swift -> BrewMenuTests/
            .deletingLastPathComponent()  // -> Tests/
            .deletingLastPathComponent()  // -> repo root
            .appendingPathComponent("Sources/Resources/RecommendedTaps.json")
        let data = try Data(contentsOf: jsonURL)
        let taps = try JSONDecoder().decode([RecommendedTap].self, from: data)

        #expect(!taps.isEmpty)
        let ids = Set(taps.map(\.id))
        #expect(ids.count == taps.count)  // no duplicate ids
        let tapNames = Set(taps.map(\.tapName))
        #expect(tapNames.count == taps.count)  // no two entries offering the same tap
        for tap in taps {
            #expect(!tap.notablePackages.isEmpty, "\(tap.id) has no notablePackages")
            #expect(tap.repositoryURL != nil, "\(tap.id)'s tapName \"\(tap.tapName)\" didn't produce a repo URL")
        }
    }

    @Test("RecommendedTap.repositoryURL deriva la URL de GitHub desde tapName (user/repo -> github.com/user/homebrew-repo)")
    func recommendedTapRepositoryURLIsDerivedCorrectly() {
        let hashicorp = RecommendedTap(
            id: "hashicorp-tap", tapName: "hashicorp/tap", title: "HashiCorp",
            subtitle: "", systemImage: "cloud",
            notablePackages: [RecommendedTapPackage(name: "terraform", url: nil)]
        )
        #expect(hashicorp.repositoryURL?.absoluteString == "https://github.com/hashicorp/homebrew-tap")

        let malformed = RecommendedTap(
            id: "bad", tapName: "not-a-valid-tap-name", title: "", subtitle: "",
            systemImage: "", notablePackages: []
        )
        #expect(malformed.repositoryURL == nil)
    }

    @Test("isTapped() refleja el estado real de taps tras addTap()")
    func isTappedReflectsAddedTaps() async {
        let service = MockBrewServiceForDashboard()
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        #expect(!vm.isTapped("hashicorp/tap"))

        let success = await vm.addTap("hashicorp/tap")

        #expect(success)
        #expect(vm.isTapped("hashicorp/tap"))
        #expect(!vm.isTapped("someone/else"))
    }

    @Test("load() puebla installedPackages, taps y ecosystems agrupa por tap único")
    func loadPopulatesEcosystems() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([
            pkg("git", tap: "homebrew/core"),
            pkg("wget", tap: "homebrew/core"),
            pkg("iterm2", tap: "homebrew/cask", isCask: true),
            pkg("my-tool", tap: "dotfn/tap"),
        ])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.load()

        #expect(vm.installedCount == 4)
        #expect(vm.ecosystems.map(\.name).sorted() == ["dotfn/tap", "homebrew/cask", "homebrew/core"])
        #expect(vm.activeEcosystemsCount == 3)
        #expect(vm.packages(in: Tap(name: "homebrew/core")).count == 2)
    }

    @Test("officialEcosystems son solo homebrew/core y homebrew/cask; el resto va a thirdPartyTaps")
    func officialVsThirdPartyEcosystems() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([
            pkg("git", tap: "homebrew/core"),
            pkg("iterm2", tap: "homebrew/cask", isCask: true),
            pkg("my-tool", tap: "dotfn/tap"),
        ])
        // "productdevbook/tap" is tapped but has nothing installed from it yet — it must
        // still show up (sourced from `taps`, not from installed packages).
        await service.setTapsResponse([
            Tap(name: "homebrew/core"), Tap(name: "homebrew/cask"),
            Tap(name: "dotfn/tap"), Tap(name: "productdevbook/tap"),
        ])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.load()

        #expect(vm.officialEcosystems.map(\.name).sorted() == ["homebrew/cask", "homebrew/core"])
        #expect(vm.thirdPartyTaps.map(\.name).sorted() == ["dotfn/tap", "productdevbook/tap"])
        #expect(vm.packages(in: Tap(name: "productdevbook/tap")).isEmpty)
    }

    @Test("officialEcosystems sigue mostrando Core/Cask aunque brew tap no los liste")
    func officialEcosystemsShowDespiteMissingFromBrewTap() async {
        // Reproduces a real Homebrew behavior: modern Homebrew serves homebrew/core and
        // homebrew/cask from a remote API without a local clone, so `brew tap` often
        // lists neither — confirmed on a real machine where `brew tap` returned only
        // third-party taps despite dozens of formulae/casks installed.
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([
            pkg("git", tap: "homebrew/core"),
            pkg("iterm2", tap: "homebrew/cask", isCask: true),
        ])
        await service.setTapsResponse([Tap(name: "dotfn/tap")])  // no core/cask here
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.load()

        #expect(vm.officialEcosystems.map(\.name).sorted() == ["homebrew/cask", "homebrew/core"])
        #expect(vm.hasAnyEcosystems)
    }

    @Test("addTap() válido llama al servicio y refresca taps")
    func addTapValidCallsServiceAndRefreshesTaps() async {
        let service = MockBrewServiceForDashboard()
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        let success = await vm.addTap("someuser/sometap")

        #expect(success)
        let calls = await service.addTapCalls
        #expect(calls == ["someuser/sometap"])
        #expect(vm.thirdPartyTaps.map(\.name) == ["someuser/sometap"])
        #expect(vm.addTapError == nil)
    }

    @Test("addTap() con formato inválido no llama al servicio")
    func addTapInvalidFormatDoesNotCallService() async {
        let service = MockBrewServiceForDashboard()
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        let success = await vm.addTap("not-a-valid-tap-name")

        #expect(!success)
        let calls = await service.addTapCalls
        #expect(calls.isEmpty)
        #expect(vm.addTapError != nil)
    }

    @Test("addTap() propaga el error del servicio (ej. tap inexistente)")
    func addTapServiceErrorIsSurfaced() async {
        let service = MockBrewServiceForDashboard()
        await service.setAddTapError(BrewError.commandFailed(exitCode: 1, stderr: "repository not found"))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        let success = await vm.addTap("ghost/doesnotexist")

        #expect(!success)
        #expect(vm.addTapError != nil)
        #expect(!vm.isAddingTap)
    }

    @Test("removeTap() llama a brew untap y refresca taps")
    func removeTapCallsServiceAndRefreshesTaps() async {
        let service = MockBrewServiceForDashboard()
        await service.setTapsResponse([Tap(name: "stablyai/orca")])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        await vm.load()
        #expect(vm.thirdPartyTaps.map(\.name) == ["stablyai/orca"])

        await vm.removeTap("stablyai/orca")

        let calls = await service.removeTapCalls
        #expect(calls == ["stablyai/orca"])
        #expect(vm.thirdPartyTaps.isEmpty)
    }

    @Test("removeTap() ante error del servicio no rompe y no queda marcado como en curso")
    func removeTapServiceErrorIsHandled() async {
        let service = MockBrewServiceForDashboard()
        await service.setTapsResponse([Tap(name: "stablyai/orca")])
        await service.setRemoveTapError(BrewError.commandFailed(exitCode: 1, stderr: "not tapped"))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        await vm.load()

        await vm.removeTap("stablyai/orca")

        #expect(vm.thirdPartyTaps.map(\.name) == ["stablyai/orca"])
        #expect(!vm.removingTapNames.contains("stablyai/orca"))
    }

    // MARK: - loadTapPackages

    @Test("loadTapPackages() puebla tapPackages desde el servicio")
    func loadTapPackagesPopulatesFromService() async {
        let service = MockBrewServiceForDashboard()
        await service.setTapPackagesResponse("dotfn/tap", [
            SearchResult(name: "portkiller", isCask: false),
            SearchResult(name: "some-app", isCask: true),
        ])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.loadTapPackages(for: "dotfn/tap")

        #expect(vm.tapPackages["dotfn/tap"]?.map(\.name) == ["portkiller", "some-app"])
        #expect(!vm.loadingTapPackagesFor.contains("dotfn/tap"))
    }

    @Test("loadTapPackages() no vuelve a pedir al servicio una vez cacheado")
    func loadTapPackagesCachesResult() async {
        let service = MockBrewServiceForDashboard()
        await service.setTapPackagesResponse("dotfn/tap", [SearchResult(name: "portkiller", isCask: false)])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.loadTapPackages(for: "dotfn/tap")
        await vm.loadTapPackages(for: "dotfn/tap")

        let calls = await service.fetchTapPackagesCalls
        #expect(calls == ["dotfn/tap"])
    }

    @Test("loadTapPackages() ante error del servicio expone el error y no lo cachea como vacío")
    func loadTapPackagesServiceErrorSurfacesError() async {
        let service = MockBrewServiceForDashboard()
        await service.setTapPackagesError(BrewError.commandFailed(exitCode: 1, stderr: "boom"))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.loadTapPackages(for: "dotfn/tap")

        // Not cached as an empty result — a transient failure shouldn't permanently
        // read as "this tap has nothing in it."
        #expect(vm.tapPackages["dotfn/tap"] == nil)
        #expect(vm.tapPackagesError["dotfn/tap"] != nil)

        // A retry (e.g. the user tapping the error state's Retry button) tries again
        // instead of being blocked by the old cache-on-failure guard.
        await service.setTapPackagesError(nil)
        await service.setTapPackagesResponse("dotfn/tap", [SearchResult(name: "portkiller", isCask: false)])
        await vm.loadTapPackages(for: "dotfn/tap")

        #expect(vm.tapPackages["dotfn/tap"]?.map(\.name) == ["portkiller"])
        #expect(vm.tapPackagesError["dotfn/tap"] == nil)
    }

    // Regression: a cancelled fetch (e.g. the driving `.task(id:)` interrupted by
    // transient SwiftUI list churn — confirmed happening once or twice right as a
    // new tap appears in the sidebar) used to be swallowed completely silently,
    // leaving tapPackages/tapPackagesError both nil — which read to the view as a
    // genuinely empty tap (the permanent "No packages installed" dead end), never
    // having actually tried. It now surfaces as a distinct, retryable error instead.
    // (Writing tapPackagesError here does NOT reintroduce the attribute-graph
    // feedback loop that a similar write to the separate `loadingTapPackagesFor`
    // property caused — that property is `@ObservationIgnored` now specifically so
    // this kind of write is safe.)
    @Test("loadTapPackages() ante cancelación expone un error reintentable, no queda mudo")
    func loadTapPackagesCancellationSurfacesRetryableError() async {
        let service = MockBrewServiceForDashboard()
        await service.setTapPackagesError(CancellationError())
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.loadTapPackages(for: "dotfn/tap")

        #expect(vm.tapPackages["dotfn/tap"] == nil)
        #expect(vm.tapPackagesError["dotfn/tap"] != nil)

        // Retrying (e.g. the user tapping Retry) still works cleanly.
        await service.setTapPackagesError(nil)
        await service.setTapPackagesResponse("dotfn/tap", [SearchResult(name: "portkiller", isCask: false)])
        await vm.loadTapPackages(for: "dotfn/tap")

        #expect(vm.tapPackages["dotfn/tap"]?.map(\.name) == ["portkiller"])
    }

    // The user shouldn't have to click Retry for a purely transient cancellation —
    // confirmed via CPU sampling that retrying *inline* within the cancellation path
    // (whether from this function or the view's own `.task`) reintroduces the exact
    // attribute-graph feedback loop this whole handling exists to avoid, no matter the
    // delay. A free-floating `Task`, decoupled from the view's structured concurrency,
    // does not. This exercises that automatic path end-to-end.
    @Test("loadTapPackages() ante cancelación reintenta automáticamente una vez, sin acción del usuario")
    func loadTapPackagesAutoRetriesOnceAfterCancellation() async {
        let service = MockBrewServiceForDashboard()
        await service.setTapPackagesError(CancellationError())
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.loadTapPackages(for: "dotfn/tap")
        #expect(vm.tapPackages["dotfn/tap"] == nil)

        // The automatic retry fires ~1s after the cancellation, on its own.
        await service.setTapPackagesError(nil)
        await service.setTapPackagesResponse("dotfn/tap", [SearchResult(name: "portkiller", isCask: false)])
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        #expect(vm.tapPackages["dotfn/tap"]?.map(\.name) == ["portkiller"])
    }

    @Test("el auto-retry ocurre a lo sumo una vez por tap")
    func loadTapPackagesAutoRetryBoundedToOnce() async {
        let service = MockBrewServiceForDashboard()
        await service.setTapPackagesError(CancellationError())
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.loadTapPackages(for: "dotfn/tap")
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // let the one auto-retry fire (still cancelling)

        let calls = await service.fetchTapPackagesCalls
        #expect(calls == ["dotfn/tap", "dotfn/tap"])  // original attempt + exactly one auto-retry
    }

    // MARK: - AddInputKind / unified Add flow

    @Test("AddInputKind.classify: user/repo es un tap, un nombre suelto o user/repo/name es un candidato a paquete")
    func classifyAddInputDistinguishesTapFromPackage() {
        #expect(AddInputKind.classify("dotfn/tap") == .tap(name: "dotfn/tap"))
        #expect(AddInputKind.classify("wget") == .packageCandidate(name: "wget"))
        #expect(AddInputKind.classify("stablyai/orca/orca") == .packageCandidate(name: "stablyai/orca/orca"))
        #expect(AddInputKind.classify("") == .invalid)
        #expect(AddInputKind.classify("a/b/c/d") == .invalid)
        #expect(AddInputKind.classify("has spaces") == .invalid)
    }

    @Test("AddInputKind.sanitize() limpia un comando 'brew install/tap' completo pegado a mano")
    func sanitizeStripsBrewCommandBoilerplate() {
        #expect(AddInputKind.sanitize("brew install --cask stablyai/orca/orca") == "stablyai/orca/orca")
        #expect(AddInputKind.sanitize("brew install wget") == "wget")
        #expect(AddInputKind.sanitize("brew tap dotfn/tap") == "dotfn/tap")
        #expect(AddInputKind.sanitize("install --cask stablyai/orca/orca") == "stablyai/orca/orca")
        #expect(AddInputKind.sanitize("$ brew install --cask stablyai/orca/orca") == "stablyai/orca/orca")
        #expect(AddInputKind.sanitize("  wget  ") == "wget")
        #expect(AddInputKind.sanitize("stablyai/orca/orca") == "stablyai/orca/orca")
        #expect(AddInputKind.sanitize("") == "")
    }

    @Test("updateAddInput() limpia el texto pegado y clasifica sobre el resultado limpio")
    func updateAddInputSanitizesPastedCommand() async {
        let service = MockBrewServiceForDashboard()
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        let cleaned = vm.updateAddInput("brew install --cask stablyai/orca/orca")

        #expect(cleaned == "stablyai/orca/orca")
        #expect(vm.addInputKind == .packageCandidate(name: "stablyai/orca/orca"))
    }

    @Test("updateAddInput() reclasifica y descarta una resolución previa")
    func updateAddInputReclassifiesAndClearsStaleResolution() async {
        let service = MockBrewServiceForDashboard()
        await service.setResolvePackageResponse(ResolvedPackage(name: "wget", tap: "homebrew/core", desc: "Internet file retriever", isCask: false))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        vm.updateAddInput("wget")
        await vm.resolvePackageCandidate("wget")
        #expect(vm.resolvedPackage != nil)

        vm.updateAddInput("dotfn/tap")

        #expect(vm.addInputKind == .tap(name: "dotfn/tap"))
        #expect(vm.resolvedPackage == nil)
    }

    @Test("resolvePackageCandidate() encuentra un formula/cask y expone tipo, tap y desc")
    func resolvePackageCandidateFindsMatch() async {
        let service = MockBrewServiceForDashboard()
        await service.setResolvePackageResponse(ResolvedPackage(name: "orca", tap: "stablyai/orca", desc: "Screen reader", isCask: true))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.resolvePackageCandidate("stablyai/orca/orca")

        #expect(vm.resolvedPackage == ResolvedPackage(name: "orca", tap: "stablyai/orca", desc: "Screen reader", isCask: true))
        #expect(vm.resolvePackageError == nil)
        let calls = await service.resolvePackageCalls
        #expect(calls == ["stablyai/orca/orca"])
    }

    @Test("resolvePackageCandidate() sin match deja un error claro y ningún paquete resuelto")
    func resolvePackageCandidateNoMatchSurfacesError() async {
        let service = MockBrewServiceForDashboard()
        await service.setResolvePackageResponse(nil)
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.resolvePackageCandidate("doesnotexist")

        #expect(vm.resolvedPackage == nil)
        #expect(vm.resolvePackageError != nil)
    }

    @Test("resolvePackageCandidate() ante un error del servicio muestra el motivo real, no un mensaje genérico")
    func resolvePackageCandidateSurfacesRealServiceError() async {
        // Regression test: BrewError didn't conform to LocalizedError, so every
        // `error.localizedDescription` in the app (this one included) fell back to a
        // useless generic bridged NSError message instead of the actual exit code + stderr.
        let service = MockBrewServiceForDashboard()
        await service.setResolvePackageError(BrewError.commandFailed(exitCode: 1, stderr: "Error: No available formula or cask with the name \"ghost\"."))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.resolvePackageCandidate("ghost")

        #expect(vm.resolvePackageError == "Command failed (code 1): Error: No available formula or cask with the name \"ghost\".")
    }

    @Test("activeCategories solo incluye categorías con al menos un paquete instalado")
    func activeCategoriesOnlyIncludesPresentOnes() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([
            pkg("docker", tap: "homebrew/core", desc: "Pack, ship and run any application as a container"),
            pkg("redis", tap: "homebrew/core", desc: "Persistent key-value database"),
            pkg("zzz-mystery", tap: "homebrew/core", desc: nil),
        ])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.load()

        #expect(vm.activeCategories == [.cloudInfrastructure, .data, .other])
        #expect(vm.count(in: .cloudInfrastructure) == 1)
        #expect(vm.packages(in: .data).map(\.name) == ["redis"])
        #expect(!vm.activeCategories.contains(.games))
    }

    @Test("load() espera a que BrewService termine de configurarse antes de leer paquetes instalados")
    func loadWaitsForConfiguration() async {
        let service = MockBrewServiceForDashboard()
        await service.setConfigured(false)  // bootstrap() still in flight
        await service.setInstalledResponse([pkg("git", tap: "homebrew/core")])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        let loadTask = Task { await vm.load() }
        try? await Task.sleep(nanoseconds: 50_000_000)  // let load() start waiting
        #expect(vm.isLoading)
        #expect(vm.installedCount == 0)  // still waiting on waitUntilConfigured()

        await service.markConfigured()
        await loadTask.value

        #expect(!vm.isLoading)
        #expect(vm.installedCount == 1)
        let calls = await service.fetchInstalledCallCount
        #expect(calls == 1)  // no retry loop — a single call once configuration resolved
    }

    // MARK: - InstalledPackagesCache (stale-while-revalidate)

    @Test("load() pinta installedPackages/taps desde el caché al instante, sin esperar el fetch real")
    func loadPaintsFromCacheInstantly() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let seedCache = InstalledPackagesCache(directory: dir)
        await seedCache.save(
            installedPackages: [pkg("cached-git", tap: "homebrew/core")],
            taps: [Tap(name: "homebrew/core")]
        )

        let service = MockBrewServiceForDashboard()
        await service.setConfigured(false)  // bootstrap() still in flight
        await service.setInstalledResponse([pkg("fresh-git", tap: "homebrew/core")])
        let vm = DashboardViewModel(
            service: service, apiClient: MockHomebrewAPIService(),
            installedPackagesCache: InstalledPackagesCache(directory: dir)
        )

        let loadTask = Task { await vm.load() }
        try? await Task.sleep(nanoseconds: 50_000_000)  // let load() prime from cache and start waiting

        // Painted from cache instantly — no spinner, doesn't wait on the real fetch.
        #expect(!vm.isLoading)
        #expect(vm.installedPackages.map(\.name) == ["cached-git"])

        await service.markConfigured()
        await loadTask.value

        // The real fetch replaces the stale cached data once it resolves.
        #expect(vm.installedPackages.map(\.name) == ["fresh-git"])
    }

    @Test("load() persiste installedPackages/taps al caché tras un fetch exitoso")
    func loadPersistsToCache() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([pkg("git", tap: "homebrew/core")])
        await service.setTapsResponse([Tap(name: "homebrew/core")])
        let vm = DashboardViewModel(
            service: service, apiClient: MockHomebrewAPIService(),
            installedPackagesCache: InstalledPackagesCache(directory: dir)
        )
        await vm.load()

        // A fresh cache instance pointed at the same directory sees the persisted data —
        // this is what the next app launch reads on startup.
        let reloaded = InstalledPackagesCache(directory: dir)
        let reloadedNames = await reloaded.installedPackages.map(\.name)
        let reloadedTaps = await reloaded.taps.map(\.name)
        #expect(reloadedNames == ["git"])
        #expect(reloadedTaps == ["homebrew/core"])
    }

    @Test("refreshInstalled() también persiste al caché")
    func refreshInstalledPersistsToCache() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([pkg("wget", tap: "homebrew/core")])
        let vm = DashboardViewModel(
            service: service, apiClient: MockHomebrewAPIService(),
            installedPackagesCache: InstalledPackagesCache(directory: dir)
        )
        await vm.refreshInstalled()

        let reloaded = InstalledPackagesCache(directory: dir)
        let reloadedNames = await reloaded.installedPackages.map(\.name)
        #expect(reloadedNames == ["wget"])
    }

    // Regression: waitUntilConfigured() used to have no way to learn a bootstrap
    // attempt had already failed (e.g. Homebrew not found) — load() would suspend
    // in isLoading forever instead of degrading to an empty, but visible, state.
    @Test("load() no cuelga si bootstrap() falló — degrada a listas vacías")
    func loadDoesNotHangWhenBootstrapFailed() async {
        let service = MockBrewServiceForDashboard()
        await service.setConfigured(false)
        await service.markBootstrapFailed(BrewError.notFound(searchedPaths: ["/opt/homebrew/bin/brew"]))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.load()

        #expect(!vm.isLoading)
        #expect(vm.installedCount == 0)
        #expect(vm.taps.isEmpty)
    }

    @Test("outdatedInstalledCount cuenta solo los que brew outdated reporta, no el campo (posiblemente stale) de brew info")
    func outdatedInstalledCountCounts() async {
        let service = MockBrewServiceForDashboard()
        // `outdated: true/false` here is the `brew info` field DashboardView.swift no
        // longer trusts for this count — deliberately disagrees with `updateLiveOutdatedNames`
        // below (the `brew outdated` source) to prove the count follows the live set,
        // not the installed-package snapshot's own flag.
        await service.setInstalledResponse([
            pkg("git", tap: "homebrew/core", outdated: false),
            pkg("wget", tap: "homebrew/core", outdated: true),
        ])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.load()
        vm.updateLiveOutdatedNames(["git"])

        #expect(vm.outdatedInstalledCount == 1)
    }

    @Test("una fetchTrending fallida degrada a lista vacía, no propaga error")
    func failedTrendingFetchDegradesGracefully() async {
        let service = MockBrewServiceForDashboard()
        let api = MockHomebrewAPIService()
        await api.setTrendingError(BrewError.outputParsingFailed(command: "GET analytics"))
        let vm = DashboardViewModel(service: service, apiClient: api, installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.load()

        #expect(vm.trendingFormulae.isEmpty)
        #expect(vm.trendingCasks.isEmpty)
        #expect(vm.installedCount == 0)
    }

    @Test("isInstalled()/isOutdated() reconocen un match de brew search calificado con el tap (user/repo/name)")
    func isInstalledMatchesTapQualifiedSearchResultName() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([
            pkg("lumus-control", tap: "dotfn/tap", isCask: true, outdated: true),
        ])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        await vm.load()
        vm.updateLiveOutdatedNames(["lumus-control"])

        // What `brew search --cask -- lumus` actually returns for a match outside the
        // default taps — the exact string SearchResultRow renders and passes through.
        #expect(vm.isInstalled("dotfn/tap/lumus-control"))
        #expect(vm.isOutdated("dotfn/tap/lumus-control"))
    }

    @Test("commitSearch() llena searchResults con lo que devuelve searchPackages")
    func commitSearchPopulatesResults() async {
        let service = MockBrewServiceForDashboard()
        await service.setSearchResponse([
            SearchResult(name: "node", isCask: false),
            SearchResult(name: "node@18", isCask: false),
        ])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.commitSearch("node")

        #expect(vm.searchResults.map(\.name) == ["node", "node@18"])
        #expect(!vm.isSearching)
    }

    @Test("commitSearch() con query vacía no busca ni pisa resultados previos")
    func commitSearchIgnoresBlankQuery() async {
        let service = MockBrewServiceForDashboard()
        await service.setSearchResponse([SearchResult(name: "node", isCask: false)])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        await vm.commitSearch("node")
        #expect(!vm.searchResults.isEmpty)

        await vm.commitSearch("   ")

        #expect(vm.searchResults.map(\.name) == ["node"])  // unchanged
    }

    @Test("updateSearch() debounce: llena searchResults después del delay (búsqueda en vivo)")
    func updateSearchDebounces() async {
        let service = MockBrewServiceForDashboard()
        await service.setSearchResponse((1...10).map { SearchResult(name: "pkg\($0)", isCask: false) })
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        vm.updateSearch(for: "pkg")
        #expect(vm.searchResults.isEmpty)  // not yet — debounce hasn't fired
        #expect(vm.isSearching)

        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(vm.searchResults.count == 10)
        #expect(!vm.isSearching)
    }

    @Test("updateSearch() con query vacía limpia los resultados")
    func updateSearchClearsOnBlank() {
        let service = MockBrewServiceForDashboard()
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        vm.updateSearch(for: "")

        #expect(vm.searchResults.isEmpty)
    }

    @Test("install() llama BrewService.installPackage y refresca installedPackages")
    func installRefreshesInstalledPackages() async {
        let service = MockBrewServiceForDashboard()
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        await vm.load()
        #expect(!vm.isInstalled("wget"))

        await vm.install(name: "wget", isCask: false)

        let calls = await service.installCalls
        #expect(calls.count == 1)
        #expect(calls[0].name == "wget")
        #expect(vm.isInstalled("wget"))
        #expect(!vm.installLog.isEmpty)
    }

    @Test("installPack() instala cada formula y cask del pack")
    func installPackInstallsAllEntries() async {
        let service = MockBrewServiceForDashboard()
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        let pack = InstallPack(
            id: "test-pack", title: "Test", subtitle: "", systemImage: "shippingbox",
            formulae: ["git", "wget"], casks: ["iterm2"]
        )

        vm.installPack(pack)  // launches its own cancelable Task internally
        for _ in 0..<50 where vm.isInstallRunning {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let calls = await service.installCalls
        #expect(calls.count == 3)
        #expect(calls.map(\.name) == ["git", "wget", "iterm2"])
        #expect(calls.last?.isCask == true)
        #expect(!vm.isInstallRunning)
        // The sheet stays up after the process finishes, until the user dismisses it —
        // see DashboardViewModel.dismissInstallSheet().
        #expect(vm.isInstalling)
    }

    @Test("cancelInstall() detiene una instalación de pack en curso")
    func cancelInstallStopsInstall() async throws {
        let service = MockBrewServiceForDashboard()
        await service.setInstallDelay(300_000_000)
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        let pack = InstallPack(
            id: "test-pack", title: "Test", subtitle: "", systemImage: "shippingbox",
            formulae: ["git", "wget"], casks: []
        )

        vm.installPack(pack)
        try await Task.sleep(nanoseconds: 50_000_000)  // let the first install start
        #expect(vm.isInstallRunning)

        vm.cancelInstall()

        // Stops the process but leaves the sheet (and its log) up — the user closes
        // it explicitly via dismissInstallSheet(), not automatically on cancel.
        #expect(!vm.isInstallRunning)
        #expect(vm.isInstalling)
    }

    @Test("install() con error no marca el paquete como instalado")
    func installFailureDoesNotMarkInstalled() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstallError(BrewError.commandFailed(exitCode: 1, stderr: "failed"))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.install(name: "wget", isCask: false)

        #expect(!vm.isInstalled("wget"))
    }

    @Test("uninstall() exitoso quita el paquete de installedPackages")
    func uninstallSuccessRemovesPackage() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([pkg("wget", tap: "homebrew/core")])
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        await vm.load()
        #expect(vm.isInstalled("wget"))

        await vm.uninstall(name: "wget", isCask: false)

        #expect(!vm.isInstalled("wget"))
        let calls = await service.uninstallCalls
        #expect(calls.map(\.name) == ["wget"])
        #expect(calls.map(\.isCask) == [false])
    }

    @Test("uninstall() con error marca failedUninstallNames y no quita el paquete")
    func uninstallFailureMarksFailedAndKeepsPackage() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstalledResponse([pkg("wget", tap: "homebrew/core")])
        await service.setUninstallError(BrewError.commandFailed(exitCode: 1, stderr: "dependency needed by other packages"))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        await vm.load()

        await vm.uninstall(name: "wget", isCask: false)

        #expect(vm.isInstalled("wget"))  // still there — the failed uninstall didn't refresh it away
        #expect(vm.failedUninstallNames.contains("wget"))
    }

    @Test("install() con error marca failedInstallNames y agrega línea visible al log")
    func installFailureMarksFailedAndLogsVisibly() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstallError(BrewError.commandFailed(exitCode: 1, stderr: "failed"))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.install(name: "wget", isCask: false)

        #expect(vm.failedInstallNames.contains("wget"))
        #expect(vm.installLog.contains { $0.hasPrefix("✗ wget failed") })
    }

    // Regression: every "Install failed" row hardcoded the same generic "check the
    // name and try again" message regardless of cause — a real, actionable Homebrew
    // error (e.g. "there's already an App at /Applications/Orca.app", confirmed
    // against a real conflicting cask install) was thrown away and never shown.
    @Test("install() con error expone el motivo real en installErrors, no un mensaje genérico")
    func installFailureSurfacesRealError() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstallError(BrewError.commandFailed(exitCode: 1, stderr: "Error: It seems there is already an App at '/Applications/Orca.app'."))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())

        await vm.install(name: "orca", isCask: true)

        #expect(vm.installErrors["orca"] == "Command failed (code 1): Error: It seems there is already an App at '/Applications/Orca.app'.")
    }

    @Test("install() exitoso limpia un failedInstallNames previo (reintento)")
    func installSuccessClearsPriorFailure() async {
        let service = MockBrewServiceForDashboard()
        await service.setInstallError(BrewError.commandFailed(exitCode: 1, stderr: "failed"))
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        await vm.install(name: "wget", isCask: false)
        #expect(vm.failedInstallNames.contains("wget"))
        #expect(vm.installErrors["wget"] != nil)

        await service.setInstallError(nil)
        await vm.install(name: "wget", isCask: false)

        #expect(!vm.failedInstallNames.contains("wget"))
        #expect(vm.installErrors["wget"] == nil)
        #expect(vm.isInstalled("wget"))
    }

    @Test("installPack() agrega una línea de resumen con éxitos y fallos")
    func installPackAppendsSummaryLine() async {
        let service = MockBrewServiceForDashboard()
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService(), installedPackagesCache: makeIsolatedInstalledPackagesCache())
        let pack = InstallPack(
            id: "test-pack", title: "Test", subtitle: "", systemImage: "shippingbox",
            formulae: ["git", "wget"], casks: []
        )

        vm.installPack(pack)
        for _ in 0..<50 where vm.isInstallRunning {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(vm.installLog.last == "✓ Installed 2/2 packages")
    }

    @Test("selectPackage() abre el target y carga el detail desde el apiClient")
    func selectPackageLoadsDetail() async throws {
        let service = MockBrewServiceForDashboard()
        let api = MockHomebrewAPIService()
        let detail = PackageDetail(
            name: "wget", isCask: false, desc: "Internet file retriever", homepage: nil,
            version: "1.24.0", requirements: [], deprecated: false, deprecationReason: nil,
            disabled: false, disableDate: nil, installs30d: 100, installs90d: 300, installs365d: 900
        )
        await api.setPackageDetailResponse(detail, for: "wget")
        let vm = DashboardViewModel(service: service, apiClient: api, installedPackagesCache: makeIsolatedInstalledPackagesCache())

        vm.selectPackage(name: "wget", isCask: false)

        #expect(vm.selectedPackageDetailTarget == PackageDetailTarget(name: "wget", isCask: false))
        #expect(vm.isLoadingPackageDetail)

        // The fetch runs in a detached Task; poll briefly for it to land.
        for _ in 0..<20 where vm.isLoadingPackageDetail {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(!vm.isLoadingPackageDetail)
        #expect(vm.packageDetail?.desc == "Internet file retriever")
        #expect(vm.packageDetail?.installs30d == 100)
    }

    @Test("selectPackage() descarta una respuesta obsoleta si el usuario ya cambió de paquete")
    func selectPackageIgnoresStaleResponse() async throws {
        let service = MockBrewServiceForDashboard()
        let api = MockHomebrewAPIService()
        // "git"'s lookup is slow; "wget"'s resolves immediately — simulates the user
        // switching targets before the first (now-stale) request lands.
        await api.setPackageDetailDelay(200_000_000, for: "git")
        await api.setPackageDetailResponse(
            PackageDetail(name: "git", isCask: false, desc: "first", homepage: nil, version: nil,
                          requirements: [], deprecated: false, deprecationReason: nil,
                          disabled: false, disableDate: nil, installs30d: nil, installs90d: nil, installs365d: nil),
            for: "git"
        )
        await api.setPackageDetailResponse(
            PackageDetail(name: "wget", isCask: false, desc: "second", homepage: nil, version: nil,
                          requirements: [], deprecated: false, deprecationReason: nil,
                          disabled: false, disableDate: nil, installs30d: nil, installs90d: nil, installs365d: nil),
            for: "wget"
        )
        let vm = DashboardViewModel(service: service, apiClient: api, installedPackagesCache: makeIsolatedInstalledPackagesCache())

        vm.selectPackage(name: "git", isCask: false)
        vm.selectPackage(name: "wget", isCask: false)  // user immediately switched targets

        for _ in 0..<50 where vm.isLoadingPackageDetail {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Give git's delayed (stale) response a chance to land too, if it were going to.
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(vm.selectedPackageDetailTarget?.name == "wget")
        #expect(vm.packageDetail?.desc == "second")  // git's late reply must not have overwritten this
    }

    // Regression: formulae.brew.sh only indexes homebrew/core and homebrew/cask, so
    // looking up a third-party package by bare name there can silently return an
    // unrelated official package that happens to share the same name (e.g. a custom
    // cask "orca" from a third-party tap vs. Homebrew's own deprecated "orca" cask).
    @Test("selectPackage() con un tap no oficial no pega contra formulae.brew.sh y no muestra datos de un paquete oficial homónimo")
    func selectPackageSkipsRemoteLookupForThirdPartyTap() async throws {
        let service = MockBrewServiceForDashboard()
        let api = MockHomebrewAPIService()
        // The *official* "orca" cask — deprecated — must never surface for the
        // third-party "stablyai/orca" cask just because the name matches.
        await api.setPackageDetailResponse(
            PackageDetail(name: "orca", isCask: true, desc: "Generate images of interactive plotly charts",
                          homepage: "https://github.com/plotly/orca/", version: "1.3.1",
                          requirements: [], deprecated: true, deprecationReason: "fails_gatekeeper_check",
                          disabled: false, disableDate: "2026-09-01",
                          installs30d: 369, installs90d: 497, installs365d: 724),
            for: "orca"
        )
        let vm = DashboardViewModel(service: service, apiClient: api, installedPackagesCache: makeIsolatedInstalledPackagesCache())

        vm.selectPackage(name: "orca", isCask: true, tap: "stablyai/orca")

        #expect(!vm.isLoadingPackageDetail)
        #expect(vm.packageDetail?.deprecated == false)
        #expect(vm.packageDetail?.desc == nil)
        #expect(vm.packageDetail?.installCommand == "brew install --cask orca")
        let calls = await api.fetchPackageDetailCallCount
        #expect(calls == 0)  // the official catalog was never queried
    }

    @Test("selectPackage() con tap oficial (o sin tap) sigue pegando contra formulae.brew.sh como antes")
    func selectPackageStillFetchesForOfficialTap() async throws {
        let service = MockBrewServiceForDashboard()
        let api = MockHomebrewAPIService()
        await api.setPackageDetailResponse(
            PackageDetail(name: "git", isCask: false, desc: "distributed version control", homepage: nil,
                          version: "2.45.0", requirements: [], deprecated: false, deprecationReason: nil,
                          disabled: false, disableDate: nil, installs30d: nil, installs90d: nil, installs365d: nil),
            for: "git"
        )
        let vm = DashboardViewModel(service: service, apiClient: api, installedPackagesCache: makeIsolatedInstalledPackagesCache())

        vm.selectPackage(name: "git", isCask: false, tap: "homebrew/core")
        for _ in 0..<50 where vm.isLoadingPackageDetail {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(vm.packageDetail?.desc == "distributed version control")
        let calls = await api.fetchPackageDetailCallCount
        #expect(calls == 1)
    }
}
