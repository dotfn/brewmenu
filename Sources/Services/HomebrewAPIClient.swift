import Foundation

protocol HomebrewAPIServicing: Actor {
    func fetchTrendingFormulae() async throws -> [TrendingPackage]
    func fetchTrendingCasks() async throws -> [TrendingPackage]
    func fetchDescription(name: String, isCask: Bool) async throws -> String?
    func fetchPackageDetail(name: String, isCask: Bool) async throws -> PackageDetail?
}

/// Talks to formulae.brew.sh's public, keyless JSON API — the only network dependency in
/// BrewMenu (everything else shells out to the local `brew` binary). Failures here must never
/// propagate as user-facing errors: callers get an empty/stale result, never a thrown error that
/// could bleed into the menu-bar status.
actor HomebrewAPIClient: HomebrewAPIServicing {
    private let session: URLSession
    private let cache: HomebrewAPICache
    private let baseURL = URL(string: "https://formulae.brew.sh/api/")!
    private let logger = BrewLogger.shared

    /// A short, explicit timeout — this client's whole contract is "never block the
    /// caller," so a stalled connection must fail fast instead of hanging on `.shared`'s
    /// much longer defaults.
    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }

    init(session: URLSession? = nil, cache: HomebrewAPICache = HomebrewAPICache()) {
        self.session = session ?? Self.makeDefaultSession()
        self.cache = cache
    }

    func fetchTrendingFormulae() async throws -> [TrendingPackage] {
        await fetchTrending(cacheKey: .trendingFormulae, path: "analytics/install/30d.json", isCask: false)
    }

    func fetchTrendingCasks() async throws -> [TrendingPackage] {
        await fetchTrending(cacheKey: .trendingCasks, path: "analytics/cask-install/30d.json", isCask: true)
    }

    func fetchDescription(name: String, isCask: Bool) async throws -> String? {
        if let cached = await cache.description(for: name) { return cached }
        let path = isCask ? "cask/\(name).json" : "formula/\(name).json"
        guard let data = try? await get(path) else { return nil }
        struct DescOnly: Decodable { let desc: String? }
        guard let decoded = try? JSONDecoder().decode(DescOnly.self, from: data) else { return nil }
        if let desc = decoded.desc { await cache.setDescription(desc, for: name) }
        return decoded.desc
    }

    /// Fetches full package detail (deprecation/disable status, requirements, and
    /// embedded 30/90/365-day install analytics) from the same per-package endpoint
    /// `fetchDescription` uses — one small request, not the full catalog.
    func fetchPackageDetail(name: String, isCask: Bool) async throws -> PackageDetail? {
        if let cached = await cache.packageDetail(for: name, isCask: isCask) { return cached }
        let path = isCask ? "cask/\(name).json" : "formula/\(name).json"
        guard let data = try? await get(path) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(PackageDetailJSON.self, from: data) else { return nil }
        let detail = decoded.detail(requestedName: name, isCask: isCask)
        await cache.setPackageDetail(detail, name: name, isCask: isCask)
        return detail
    }

    // MARK: - Private

    private func fetchTrending(cacheKey: HomebrewAPICache.TrendingKey, path: String, isCask: Bool) async -> [TrendingPackage] {
        if let fresh = await cache.freshTrending(cacheKey) { return fresh }
        do {
            let data = try await get(path)
            let output = try JSONDecoder().decode(AnalyticsOutput.self, from: data)
            let packages = output.trendingPackages(isCask: isCask)
            await cache.setTrending(packages, for: cacheKey)
            return packages
        } catch {
            await logger.log("HomebrewAPIClient: fetch \(path) failed — \(error.localizedDescription)", .warn)
            return await cache.staleTrending(cacheKey) ?? []
        }
    }

    private func get(_ path: String) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BrewError.outputParsingFailed(command: "GET \(path)")
        }
        return data
    }
}

/// On-disk cache for API responses, following the same actor + JSON-file pattern as `SettingsStore`.
actor HomebrewAPICache {
    enum TrendingKey: String, Codable { case trendingFormulae, trendingCasks }

    private struct CacheFile: Codable {
        var trending: [String: TrendingEntry] = [:]
        var descriptions: [String: String] = [:]
        var packageDetails: [String: PackageDetailEntry] = [:]
    }

    private struct TrendingEntry: Codable {
        let packages: [TrendingPackage]
        let fetchedAt: Date
    }

    private struct PackageDetailEntry: Codable {
        let detail: PackageDetail
        let fetchedAt: Date
    }

    private static let ttl: TimeInterval = 24 * 60 * 60
    // Shorter than trending/description: deprecation status and analytics counts
    // shift more often, and a detail sheet is opened on demand, not pre-warmed.
    private static let packageDetailTTL: TimeInterval = 6 * 60 * 60

    private let fileURL: URL
    private var file: CacheFile
    /// Coalesces bursts of `persist()` calls (e.g. one per row as a list of search
    /// results resolves its descriptions) into a single full-file write instead of one
    /// per mutation — see `persist()`.
    private var persistScheduled = false

    /// `directory` is injectable so tests can point the cache at an isolated temp
    /// directory instead of the real Application Support folder.
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.brewMenuSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("api-cache.json")
        self.file = Self.load(from: fileURL) ?? CacheFile()
    }

    /// Returns cached trending data only if still within the TTL.
    func freshTrending(_ key: TrendingKey) -> [TrendingPackage]? {
        guard let entry = file.trending[key.rawValue],
              Date().timeIntervalSince(entry.fetchedAt) < Self.ttl else { return nil }
        return entry.packages
    }

    /// Returns cached trending data regardless of age — used as a fallback when a live fetch fails.
    func staleTrending(_ key: TrendingKey) -> [TrendingPackage]? {
        file.trending[key.rawValue]?.packages
    }

    func setTrending(_ packages: [TrendingPackage], for key: TrendingKey) {
        file.trending[key.rawValue] = TrendingEntry(packages: packages, fetchedAt: Date())
        persist()
    }

    func description(for name: String) -> String? {
        file.descriptions[name]
    }

    func setDescription(_ desc: String, for name: String) {
        file.descriptions[name] = desc
        persist()
    }

    func packageDetail(for name: String, isCask: Bool) -> PackageDetail? {
        guard let entry = file.packageDetails[detailKey(name, isCask)],
              Date().timeIntervalSince(entry.fetchedAt) < Self.packageDetailTTL else { return nil }
        return entry.detail
    }

    func setPackageDetail(_ detail: PackageDetail, name: String, isCask: Bool) {
        file.packageDetails[detailKey(name, isCask)] = PackageDetailEntry(detail: detail, fetchedAt: Date())
        persist()
    }

    private func detailKey(_ name: String, _ isCask: Bool) -> String { "\(name)-\(isCask)" }

    // MARK: - Private

    /// Schedules a single debounced write instead of one full-file re-encode+write per
    /// mutation. Each row in Search Results / Recommended resolves its own description or
    /// detail independently, so without coalescing, a list of N rows meant N full rewrites
    /// of the whole (ever-growing) cache file. A `persist()` call while one is already
    /// pending is a no-op; the eventual flush picks up every mutation made in the meantime.
    private func persist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.flush()
        }
    }

    private func flush() {
        persistScheduled = false
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> CacheFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }
}
