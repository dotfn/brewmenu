import BrewCore
@testable import BrewMenu
import Foundation
import Testing

/// Its own URLProtocol, not `MockURLProtocol`: that one's handler is shared with the
/// HomebrewAPIClient suite, and the two suites may run at the same time.
final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    /// Answers by file name (`formula.json`, `cask.json`): status, body, and the ETag to send.
    nonisolated(unsafe) static var handler: @Sendable (URLRequest) -> (Int, Data, String?) = { _ in (404, Data(), nil) }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (status, data, etag) = Self.handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: etag.map { ["ETag": $0] }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private let formulaJSON = """
[
  {"name": "git", "tap": "homebrew/core", "desc": "Distributed revision control system",
   "homepage": "https://git-scm.com", "versions": {"stable": "2.56.1"}, "aliases": [], "oldnames": [],
   "deprecated": false, "disabled": false},
  {"name": "postgresql@18", "tap": "homebrew/core", "desc": "Object-relational database system",
   "homepage": "https://www.postgresql.org/", "versions": {"stable": "18.1"}, "aliases": ["postgresql"],
   "oldnames": [], "deprecated": false, "disabled": false},
  {"name": "terraform", "tap": "homebrew/core", "desc": "Tool to build, change, and version infrastructure",
   "homepage": "https://www.terraform.io/", "versions": {"stable": "1.5.7"}, "deprecated": true, "disabled": false}
]
"""

private let caskJSON = """
[
  {"token": "visual-studio-code", "tap": "homebrew/cask", "name": ["Microsoft Visual Studio Code", "VS Code"],
   "desc": "Open-source code editor", "homepage": "https://code.visualstudio.com/", "version": "1.146.0",
   "deprecated": false, "disabled": false,
   "artifacts": [{"uninstall": [{"quit": "com.microsoft.VSCode"}]},
                 {"app": ["Visual Studio Code.app"], "target": "/Applications/Visual Studio Code.app"},
                 {"zap": [{"trash": ["~/.vscode"]}]}]},
  {"token": "font-fira-code", "tap": "homebrew/cask", "name": ["Fira Code"], "desc": null,
   "homepage": "https://github.com/tonsky/FiraCode", "version": "6.2", "artifacts": [{"font": ["FiraCode.ttf"]}]},
  {"token": "gitkraken", "tap": "homebrew/cask", "name": ["GitKraken"], "desc": "Git client focusing on productivity",
   "homepage": "https://www.gitkraken.com/", "version": "11.5.0",
   "artifacts": [{"app": ["GitKraken.app", {"target": "GitKraken Pro.app"}]}]}
]
"""

@Suite("PackageCatalog — catálogo completo en disco", .serialized)
struct PackageCatalogTests {
    private func makeCatalog() -> (PackageCatalog, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogURLProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (PackageCatalog(directory: directory, session: URLSession(configuration: config)), directory)
    }

    private static func serveCatalog(etag: String = "\"v1\"", notModifiedFor knownETag: String? = nil) {
        CatalogURLProtocol.handler = { request in
            if let knownETag, request.value(forHTTPHeaderField: "If-None-Match") == knownETag {
                return (304, Data(), knownETag)
            }
            let body = request.url?.lastPathComponent == "cask.json" ? caskJSON : formulaJSON
            return (200, Data(body.utf8), etag)
        }
    }

    @Test("descarga ambos archivos y decodifica fórmulas y casks con lo que muestra la app")
    func downloadsAndDecodes() async throws {
        Self.serveCatalog()
        let (catalog, _) = makeCatalog()

        let index = try #require(try await catalog.refresh())

        #expect(index.packages.count == 6)
        let code = try #require(index.package(named: "visual-studio-code", isCask: true))
        #expect(code.displayName == "Microsoft Visual Studio Code")
        #expect(code.appPath == "/Applications/Visual Studio Code.app")
        #expect(index.package(named: "gitkraken", isCask: true)?.appPath == "/Applications/GitKraken Pro.app")
        #expect(index.package(named: "font-fira-code", isCask: true)?.isApp == false)
        #expect(index.package(named: "terraform", isCask: false)?.deprecated == true)
        #expect(index.apps.map(\.name).sorted() == ["gitkraken", "visual-studio-code"])
    }

    @Test("con el ETag guardado, un 304 no vuelve a decodificar y el disco sigue sirviendo")
    func notModifiedKeepsTheCopyOnDisk() async throws {
        Self.serveCatalog(etag: "\"v1\"")
        let (catalog, _) = makeCatalog()
        _ = try await catalog.refresh()

        Self.serveCatalog(etag: "\"v1\"", notModifiedFor: "\"v1\"")
        let unchanged = try await catalog.refresh()

        #expect(unchanged == nil)
        #expect(try await catalog.cached()?.packages.count == 6)
        #expect(await catalog.downloadedAt() != nil)
    }

    // Regression: a download that didn't decode replaced the good copy first, then deleted both
    // files — the last good catalog was gone, and every Dashboard open downloaded it again.
    @Test("una descarga que no se puede leer no reemplaza la copia buena")
    func badDownloadKeepsTheLastGoodCopy() async throws {
        Self.serveCatalog(etag: "\"v1\"")
        let (catalog, directory) = makeCatalog()
        _ = try await catalog.refresh()

        CatalogURLProtocol.handler = { _ in (200, Data("{ not json".utf8), "\"bad\"") }
        await #expect(throws: DecodingError.self) { try await catalog.refresh() }

        #expect(try await catalog.cached()?.packages.count == 6)
        let etag = try String(contentsOf: directory.appendingPathComponent("formula.json.etag"), encoding: .utf8)
        #expect(etag == "\"v1\"")
    }

    @Test("una entrada que no se puede leer se salta sin perder el resto del archivo")
    func oneBadEntryIsSkipped() async throws {
        // 1 bad entry in 3 would be over the 1% limit, so this pads the file with good ones.
        let good = (0 ..< 120).map {
            #"{"name": "tool\#($0)", "desc": "A tool", "versions": {"stable": "1.0"}}"#
        }
        let body = "[" + (good + [#"{"name": 42, "versions": "nope"}"#]).joined(separator: ",") + "]"
        CatalogURLProtocol.handler = { request in
            request.url?.lastPathComponent == "cask.json"
                ? (200, Data(caskJSON.utf8), nil)
                : (200, Data(body.utf8), nil)
        }
        let (catalog, _) = makeCatalog()

        let index = try #require(try await catalog.refresh())

        #expect(index.formulae.count == 120)
        #expect(index.apps.count == 2)
    }

    @Test("si más del 1% de las entradas no se lee, el formato cambió: se rechaza y queda la copia buena")
    func formatChangeIsRejected() async throws {
        Self.serveCatalog()
        let (catalog, _) = makeCatalog()
        _ = try await catalog.refresh()

        CatalogURLProtocol.handler = { request in
            request.url?.lastPathComponent == "cask.json"
                ? (200, Data(caskJSON.utf8), "\"v2\"")
                : (200, Data(#"[{"title": "git"}, {"title": "wget"}]"#.utf8), "\"v2\"")
        }
        await #expect(throws: PackageCatalogError.self) { try await catalog.refresh() }

        #expect(try await catalog.cached()?.package(named: "git", isCask: false) != nil)
    }

    @Test("el target de una app renombrada se respeta aunque falte el target del artefacto")
    func renamedAppTargetInsideAppList() async throws {
        Self.serveCatalog()
        let (catalog, _) = makeCatalog()

        let index = try #require(try await catalog.refresh())

        #expect(index.package(named: "gitkraken", isCask: true)?.appPath == "/Applications/GitKraken Pro.app")
    }
}

@Suite("PackageCatalogIndex — búsqueda local")
struct PackageCatalogIndexTests {
    private let index = PackageCatalogIndex(packages: [
        CatalogPackage(name: "git", desc: "Distributed revision control system", version: "2.56", isCask: false),
        CatalogPackage(name: "gitui", desc: "Blazing fast terminal-ui for git", version: "0.27", isCask: false),
        CatalogPackage(name: "lazygit", desc: "Simple terminal UI for git commands", version: "0.55", isCask: false),
        CatalogPackage(
            name: "postgresql@18",
            desc: "Object-relational database system",
            version: "18.1",
            isCask: false,
            aliases: ["postgresql"]
        ),
        CatalogPackage(
            name: "visual-studio-code",
            displayName: "Microsoft Visual Studio Code",
            desc: "Open-source code editor",
            version: "1.146",
            isCask: true,
            appPath: "/Applications/Visual Studio Code.app"
        ),
    ])

    @Test("nombre exacto primero, después prefijo, después en cualquier parte del nombre")
    func namesRankByHowTheyMatch() {
        #expect(index.search("git").map(\.name) == ["git", "gitui", "lazygit"])
    }

    @Test("busca también por alias, nombre visible y descripción")
    func searchesAliasesDisplayNamesAndDescriptions() {
        #expect(index.search("postgresql").map(\.name) == ["postgresql@18"])
        #expect(index.search("Visual Studio").map(\.name) == ["visual-studio-code"])
        #expect(index.search("database system").map(\.name) == ["postgresql@18"])
    }

    @Test("a igual coincidencia gana el más instalado")
    func tiesGoToTheMorePopular() {
        let ranked = index.search("terminal") { $0.name == "lazygit" ? 100 : 1 }
        #expect(ranked.map(\.name) == ["lazygit", "gitui"])
    }

    @Test("un nombre de un tap de terceros no se confunde con el paquete oficial del mismo nombre")
    func thirdPartyNamesDontResolveToOfficialPackages() {
        #expect(index.package(named: "homebrew/core/git", isCask: false)?.name == "git")
        #expect(index.package(named: "someone/tap/git", isCask: false) == nil)
    }
}

/// Regression coverage for the sync-before-change rule: the app turns off Homebrew's own
/// auto-update for every command, so nothing refreshed the database before an install.
@Suite("BrewStore — base de paquetes al día antes de cambiar algo")
@MainActor
struct DatabaseSyncTests {
    @Test("una base de más de 15 minutos se actualiza antes del upgrade, y el log lo dice")
    func staleDatabaseSyncsBeforeUpgrade() async {
        let service = MockBrewService()
        await service.setDatabaseFetchedAt(Date(timeIntervalSinceNow: -3600))
        let menuBar = MenuBarViewModel(service: service)
        await menuBar.performBootstrap()

        await menuBar.performUpgradeAll()

        #expect(await service.updateCallCount == 1)
        #expect(menuBar.upgradeLog.first == L("Updating the package database…"))
    }

    @Test("una base recién actualizada no se vuelve a actualizar")
    func freshDatabaseIsLeftAlone() async {
        let service = MockBrewService()
        await service.setDatabaseFetchedAt(Date(timeIntervalSinceNow: -60))
        let menuBar = MenuBarViewModel(service: service)
        await menuBar.performBootstrap()

        await menuBar.performUpgradeAll()

        #expect(await service.updateCallCount == 0)
        #expect(!menuBar.upgradeLog.contains(L("Updating the package database…")))
    }

    @Test("después de sincronizar, la base cuenta como al día para el siguiente cambio")
    func syncDatesTheDatabase() async {
        let service = MockBrewService()
        let store = BrewStore(service: service)

        #expect(await store.syncDatabaseIfStale())
        #expect(await !(store.syncDatabaseIfStale()))
        #expect(await service.updateCallCount == 1)
    }
}

@Suite("BrewStore — cancelaciones y brew update de a uno")
@MainActor
struct BrewStoreConcurrencyTests {
    // Regression: resetting the check interval cancels a running check, and that cancellation
    // was recorded as the check's error — the menu bar showed it until the next good check.
    @Test("un chequeo cancelado no deja un error en el menú")
    func cancelledCheckLeavesNoError() async {
        let service = MockBrewService()
        await service.setFetchError(CancellationError())
        let store = BrewStore(service: service)

        await store.runScheduledCheck(BrewStore.CheckPlan())

        #expect(store.lastError == nil)
        #expect(store.failures[.outdated] == nil)
    }

    @Test("dos cambios con la base vieja corren un solo brew update")
    func concurrentSyncsShareOneUpdate() async throws {
        let service = MockBrewService()
        await service.holdUpdate()
        let store = BrewStore(service: service)

        async let first = store.syncDatabaseIfStale()
        async let second = store.syncDatabaseIfStale()
        try await waitUntil { await service.updateCallCount == 1 }
        await service.releaseUpdate()
        _ = await (first, second)

        #expect(await service.updateCallCount == 1)
    }

    @Test("la lista de apps por popularidad se ordena una vez por catálogo y por conteos")
    func rankingIsKeyedOnVersions() async {
        let service = MockBrewServiceForDashboard()
        let api = MockHomebrewAPIService()
        await api.setTrendingCasks([TrendingPackage(name: "b-app", installCount: 50, isCask: true)])
        let catalog = StubCatalog(PackageCatalogIndex(packages: [
            CatalogPackage(name: "a-app", desc: nil, version: "1", isCask: true, appPath: "/Applications/A.app"),
            CatalogPackage(name: "b-app", desc: nil, version: "1", isCask: true, appPath: "/Applications/B.app"),
        ]))
        let store = BrewStore(service: service, packageCatalog: catalog)
        let dashboard = DashboardViewModel(service: service, apiClient: api, store: store)
        await dashboard.loadTrending()
        await store.loadCatalog()

        let key = dashboard.rankingKey(apps: true, byPopularity: true)
        await dashboard.rank(key)

        #expect(dashboard.ranking(for: key)?.map(\.name) == ["b-app", "a-app"])
        #expect(dashboard.ranking(for: dashboard.rankingKey(apps: true, byPopularity: false)) == nil)
    }
}

/// A catalog that's always there and never downloads.
private actor StubCatalog: PackageCatalogServicing {
    let index: PackageCatalogIndex

    init(_ index: PackageCatalogIndex) {
        self.index = index
    }

    func cached() async throws -> PackageCatalogIndex? {
        index
    }

    func downloadedAt() -> Date? {
        Date()
    }

    func refresh() async throws -> PackageCatalogIndex? {
        nil
    }
}
