import Testing
import Foundation
@testable import BrewMenu

// MARK: - Mock URLProtocol

/// Intercepts URLSession requests so tests never touch the real network.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data)) = { _ in (200, Data()) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// A fresh, isolated cache directory per call so tests never touch the real
/// Application Support folder or leak state between runs.
private func makeIsolatedCache() -> HomebrewAPICache {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return HomebrewAPICache(directory: dir)
}

private func makeClient() -> HomebrewAPIClient {
    HomebrewAPIClient(session: makeMockSession(), cache: makeIsolatedCache())
}

// MARK: - Fixtures

private let formulaeAnalyticsJSON = """
{
  "items": [
    {"number": 1, "formula": "openssl@3", "count": "565,592", "percent": "2.64"},
    {"number": 2, "formula": "node", "count": "1,234", "percent": "0.10"}
  ]
}
"""

private let caskAnalyticsJSON = """
{
  "items": [
    {"number": 1, "cask": "iterm2", "count": "93,203", "percent": "4.09"}
  ]
}
"""

// Trimmed real shape from formulae.brew.sh/api/formula/heroku.json.
private let formulaDetailJSON = """
{
  "desc": "Command-line tool for Heroku",
  "homepage": "https://www.heroku.com/",
  "versions": {"stable": "9.11.0"},
  "deprecated": false,
  "disabled": false,
  "requirements": [],
  "analytics": {
    "install": {
      "30d": {"heroku": 1370},
      "90d": {"heroku": 4095},
      "365d": {"heroku": 15129}
    }
  }
}
"""

// Trimmed real shape from formulae.brew.sh/api/cask/orca.json — deprecated/disabled.
private let caskDetailDeprecatedJSON = """
{
  "desc": "Generate images of interactive plotly charts",
  "homepage": "https://github.com/plotly/orca/",
  "version": "1.3.1",
  "deprecated": true,
  "deprecation_reason": "fails_gatekeeper_check",
  "disabled": false,
  "disable_date": "2026-09-01",
  "requirements": null,
  "analytics": {
    "install": {
      "30d": {"orca": 356},
      "90d": {"orca": 483},
      "365d": {"orca": 712}
    }
  }
}
"""

// MARK: - Tests

// Serialized: all tests mutate the shared `MockURLProtocol.handler` static, so they
// can't run concurrently without racing each other's request/response pairing.
@Suite("HomebrewAPIClient", .serialized)
struct HomebrewAPIClientTests {

    @Test("fetchTrendingFormulae parsea count con comas")
    func fetchTrendingFormulaeParsesCounts() async throws {
        MockURLProtocol.handler = { _ in (200, formulaeAnalyticsJSON.data(using: .utf8)!) }
        let client = makeClient()

        let packages = try await client.fetchTrendingFormulae()

        #expect(packages.count == 2)
        #expect(packages[0].name == "openssl@3")
        #expect(packages[0].installCount == 565_592)
        #expect(packages[0].isCask == false)
        #expect(packages[1].installCount == 1_234)
    }

    @Test("fetchTrendingCasks parsea items del endpoint de casks")
    func fetchTrendingCasksParsesItems() async throws {
        MockURLProtocol.handler = { _ in (200, caskAnalyticsJSON.data(using: .utf8)!) }
        let client = makeClient()

        let packages = try await client.fetchTrendingCasks()

        #expect(packages.count == 1)
        #expect(packages[0].name == "iterm2")
        #expect(packages[0].isCask)
    }

    @Test("fetchTrendingFormulae ante fallo de red devuelve vacío sin cache previa")
    func fetchTrendingFormulaeDegradesOnFailure() async throws {
        MockURLProtocol.handler = { _ in (500, Data()) }
        let client = makeClient()

        let packages = try await client.fetchTrendingFormulae()

        #expect(packages.isEmpty)
    }

    @Test("fetchTrendingFormulae usa cache stale cuando la red falla tras un fetch exitoso")
    func fetchTrendingFormulaeFallsBackToStaleCache() async throws {
        let cache = makeIsolatedCache()
        let session = makeMockSession()

        MockURLProtocol.handler = { _ in (200, formulaeAnalyticsJSON.data(using: .utf8)!) }
        let client = HomebrewAPIClient(session: session, cache: cache)
        let first = try await client.fetchTrendingFormulae()
        #expect(first.count == 2)

        MockURLProtocol.handler = { _ in (500, Data()) }
        let second = try await client.fetchTrendingFormulae()

        #expect(second.count == 2)
        #expect(second[0].name == "openssl@3")
    }

    @Test("fetchDescription devuelve el desc del formula/cask")
    func fetchDescriptionParsesDesc() async throws {
        MockURLProtocol.handler = { _ in (200, #"{"desc":"Internet file retriever"}"#.data(using: .utf8)!) }
        let client = makeClient()

        let desc = try await client.fetchDescription(name: "wget", isCask: false)

        #expect(desc == "Internet file retriever")
    }

    @Test("fetchDescription ante fallo de red devuelve nil")
    func fetchDescriptionReturnsNilOnFailure() async throws {
        MockURLProtocol.handler = { _ in (404, Data()) }
        let client = makeClient()

        let desc = try await client.fetchDescription(name: "unknown", isCask: false)

        #expect(desc == nil)
    }

    @Test("fetchPackageDetail parsea desc, version y analytics de una formula")
    func fetchPackageDetailParsesFormula() async throws {
        MockURLProtocol.handler = { _ in (200, formulaDetailJSON.data(using: .utf8)!) }
        let client = makeClient()

        let detail = try await client.fetchPackageDetail(name: "heroku", isCask: false)

        #expect(detail?.desc == "Command-line tool for Heroku")
        #expect(detail?.version == "9.11.0")  // pulled from versions.stable for formulae
        #expect(detail?.deprecated == false)
        #expect(detail?.installs30d == 1370)
        #expect(detail?.installs90d == 4095)
        #expect(detail?.installs365d == 15129)
        #expect(detail?.installCommand == "brew install heroku")
    }

    @Test("fetchPackageDetail parsea deprecated/disable_date de un cask")
    func fetchPackageDetailParsesDeprecatedCask() async throws {
        MockURLProtocol.handler = { _ in (200, caskDetailDeprecatedJSON.data(using: .utf8)!) }
        let client = makeClient()

        let detail = try await client.fetchPackageDetail(name: "orca", isCask: true)

        #expect(detail?.version == "1.3.1")  // pulled from plain `version` for casks
        #expect(detail?.deprecated == true)
        #expect(detail?.deprecationReason == "fails_gatekeeper_check")
        #expect(detail?.disableDate == "2026-09-01")
        #expect(detail?.installs365d == 712)
        #expect(detail?.installCommand == "brew install --cask orca")
    }

    @Test("fetchPackageDetail ante fallo de red devuelve nil")
    func fetchPackageDetailReturnsNilOnFailure() async throws {
        MockURLProtocol.handler = { _ in (404, Data()) }
        let client = makeClient()

        let detail = try await client.fetchPackageDetail(name: "unknown", isCask: false)

        #expect(detail == nil)
    }
}
