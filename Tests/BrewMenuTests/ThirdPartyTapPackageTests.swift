import BrewCore
@testable import BrewMenu
import Foundation
import Testing

/// Packages from third-party taps, which formulae.brew.sh doesn't index: what their taps say,
/// read by `brew info`, in the search results and on their pages.
@Suite("Paquetes de taps de terceros", .serialized)
@MainActor
struct ThirdPartyTapPackageTests {
    @Test(
        "selectPackage() con un tap no oficial no pega contra formulae.brew.sh y no muestra datos de un paquete oficial homónimo"
    )
    func selectPackageSkipsRemoteLookupForThirdPartyTap() async {
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
        let vm = DashboardViewModel(
            service: service,
            apiClient: api,
            installedPackagesCache: makeIsolatedInstalledPackagesCache()
        )

        vm.selectPackage(name: "orca", isCask: true, tap: "stablyai/orca")
        try? await waitUntil { !vm.isLoadingPackageDetail }

        // brew couldn't read it either (the mock knows nothing): its name and command, no error.
        #expect(vm.packageDetail?.deprecated == false)
        #expect(vm.packageDetail?.desc == nil)
        #expect(vm.packageDetail?.installCommand == "brew install --cask stablyai/orca/orca")
        #expect(await service.tapInfoCalls == [["stablyai/orca/orca"]])
        let calls = await api.fetchPackageDetailCallCount
        #expect(calls == 0) // the official catalog was never queried
    }

    private static let dotphin = CatalogPackage(
        name: "dotfn/tap/dotphin",
        displayName: "Dotphin",
        desc: "File manager inspired by KDE Dolphin",
        version: "0.1.2-beta",
        homepage: "https://github.com/dotfn/dotphin",
        isCask: true,
        tap: "dotfn/tap",
        appPath: "/Applications/Dotphin.app"
    )

    @Test(
        "la ficha de un paquete de un tap de terceros sale de su tap, abierta desde la búsqueda o desde Installed",
        arguments: [
            PackageDetailTarget(name: "dotfn/tap/dotphin", isCask: true, tap: nil),
            PackageDetailTarget(name: "dotphin", isCask: true, tap: "dotfn/tap"),
        ]
    )
    func thirdPartyDetailFromItsTap(target: PackageDetailTarget) async throws {
        let service = MockBrewServiceForDashboard()
        await service.setTapInfo([Self.dotphin])
        let api = MockHomebrewAPIService()
        let vm = DashboardViewModel(
            service: service,
            apiClient: api,
            installedPackagesCache: makeIsolatedInstalledPackagesCache()
        )

        vm.selectPackage(name: target.name, isCask: target.isCask, tap: target.tap)
        try await waitUntil { !vm.isLoadingPackageDetail }

        #expect(vm.packageDetail?.desc == "File manager inspired by KDE Dolphin")
        #expect(vm.packageDetail?.version == "0.1.2-beta")
        #expect(vm.packageDetail?.installCommand == "brew install --cask dotfn/tap/dotphin")
        #expect(vm.store.catalogPackage(named: target.qualifiedName, isCask: true)?.displayName == "Dotphin")
        #expect(await api.fetchPackageDetailCallCount == 0)

        // Read once: opening it again doesn't start brew.
        vm.selectPackage(name: target.name, isCask: target.isCask, tap: target.tap)
        #expect(!vm.isLoadingPackageDetail)
        #expect(await service.tapInfoCalls.count == 1)
    }

    @Test("una búsqueda lee de una vez lo que dicen sus taps de los resultados de terceros")
    func searchReadsThirdPartyResults() async throws {
        let service = MockBrewServiceForDashboard()
        await service.setTapInfo([Self.dotphin])
        await service.setSearchResponse([SearchResult(name: "dotfn/tap/dotphin", isCask: true)])
        let vm = DashboardViewModel(
            service: service,
            apiClient: MockHomebrewAPIService(),
            installedPackagesCache: makeIsolatedInstalledPackagesCache()
        )

        await vm.commitSearch("dotphin")
        try await waitUntil { vm.store.tapPackages["dotfn/tap/dotphin"] != nil }

        #expect(await service.tapInfoCalls == [["dotfn/tap/dotphin"]])
        #expect(vm.store.catalogPackage(named: "dotfn/tap/dotphin", isCask: true)?
            .appPath == "/Applications/Dotphin.app")
        #expect(vm.store.catalogPackage(named: "dotfn/tap/dotphin", isCask: false) == nil, "a cask isn't a formula")
    }

    @Test("si brew no puede leer uno, los demás se leen igual")
    func oneUnreadableTapPackage() async {
        let service = MockBrewServiceForDashboard()
        await service.setTapInfo([Self.dotphin])
        let vm = DashboardViewModel(
            service: service,
            apiClient: MockHomebrewAPIService(),
            installedPackagesCache: makeIsolatedInstalledPackagesCache()
        )

        await vm.store.loadTapPackages(["dotfn/tap/dotphin", "gone/tap/thing", "wget"])

        #expect(vm.store.tapPackages.keys.sorted() == ["dotfn/tap/dotphin"])
        #expect(await service.tapInfoCalls.first?.contains("wget") == false, "an official name isn't asked")
    }
}

@Suite("brew info de paquetes de taps de terceros")
struct BrewInfoCatalogOutputTests {
    @Test("se lee igual que el catálogo, con el nombre completo para no confundirlo con uno oficial")
    func decodesRealOutput() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/brew-info-third-party.json")
        let output = try JSONDecoder().decode(BrewInfoCatalogOutput.self, from: Data(contentsOf: url))

        let axe = try #require(output.packages.first { !$0.isCask })
        #expect(axe.name == "cameroncooke/axe/axe")
        #expect(axe.displayName == "axe", "user/repo/ is for brew, not for reading")
        #expect(axe.tap == "cameroncooke/axe")
        #expect(axe.desc?.isEmpty == false)

        let dotphin = try #require(output.packages.first { $0.isCask })
        #expect(dotphin.name == "dotfn/tap/dotphin")
        #expect(dotphin.displayName == "Dotphin")
        #expect(dotphin.desc == "File manager inspired by KDE Dolphin")
        #expect(dotphin.appPath == "/Applications/Dotphin.app")
    }
}
