import BrewCore
import Foundation

protocol PackageCatalogServicing: Actor {
    /// The catalog from the last download, or nil when there's none on disk yet.
    func cached() async throws -> PackageCatalogIndex?
    /// When the copy on disk was downloaded, or nil when there's none.
    func downloadedAt() -> Date?
    /// Downloads what changed since last time. Returns the new catalog, or nil when nothing did.
    func refresh() async throws -> PackageCatalogIndex?
}

/// Homebrew's full catalog — every formula and cask in homebrew/core and homebrew/cask — kept on
/// disk so browsing and searching never start `brew`. It's formulae.brew.sh's public `formula.json`
/// and `cask.json` (documented and stable, unlike Homebrew's own internal cache files), fetched
/// with `If-None-Match` so an unchanged file costs a 304.
///
/// The files live in Caches: they can be downloaded again at any time, and a purged folder only
/// means the next refresh downloads them in full.
actor PackageCatalog: PackageCatalogServicing {
    private enum File: String, CaseIterable {
        case formula, cask

        var name: String {
            "\(rawValue).json"
        }
    }

    private let directory: URL
    private let session: URLSession
    private let baseURL: URL
    private let logger: BrewLogger

    /// Longer timeouts than `HomebrewAPIClient`'s: these are two multi-megabyte downloads, not
    /// small JSON calls. No `URLCache` either — the ETags below are the cache, and the files
    /// themselves the stored copy.
    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }

    init(
        directory: URL? = nil,
        session: URLSession? = nil,
        baseURL: URL = URL(string: "https://formulae.brew.sh/api/")!,
        logger: BrewLogger = .shared
    ) {
        self.directory = directory ?? FileManager.brewMenuCachesDirectory.appendingPathComponent("catalog")
        self.session = session ?? Self.makeDefaultSession()
        self.baseURL = baseURL
        self.logger = logger
    }

    /// A copy that isn't valid JSON is deleted with its ETag, so the next refresh downloads it in
    /// full instead of being told "not modified" about a file nobody can read. One that is valid
    /// but in a format this version can't read is kept: downloading it again wouldn't change it.
    func cached() async throws -> PackageCatalogIndex? {
        guard File.allCases.allSatisfy({ FileManager.default.fileExists(atPath: url(for: $0).path) }) else {
            return nil
        }
        do {
            return try await decode(formula: url(for: .formula), cask: url(for: .cask))
        } catch let DecodingError.dataCorrupted(context) {
            for file in File.allCases {
                try? FileManager.default.removeItem(at: url(for: file))
                try? FileManager.default.removeItem(at: etagURL(for: file))
            }
            throw DecodingError.dataCorrupted(context)
        }
    }

    func downloadedAt() -> Date? {
        File.allCases
            .compactMap {
                try? url(for: $0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            .min()
    }

    /// What's downloaded goes to a staging file first, and replaces the copy on disk only once
    /// both files decode: a bad download must not cost the last good catalog.
    func refresh() async throws -> PackageCatalogIndex? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var staged: [File: (url: URL, etag: String?)] = [:]
        defer {
            for download in staged.values {
                try? FileManager.default.removeItem(at: download.url)
            }
        }
        for file in File.allCases {
            if let download = try await download(file) { staged[file] = download }
        }
        guard !staged.isEmpty else { return nil }
        let index = try await decode(
            formula: staged[.formula]?.url ?? url(for: .formula),
            cask: staged[.cask]?.url ?? url(for: .cask)
        )
        for (file, download) in staged {
            _ = try FileManager.default.replaceItemAt(url(for: file), withItemAt: download.url)
            if let etag = download.etag {
                try etag.write(to: etagURL(for: file), atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: etagURL(for: file))
            }
        }
        return index
    }

    // MARK: - Private

    private func url(for file: File) -> URL {
        directory.appendingPathComponent(file.name)
    }

    private func etagURL(for file: File) -> URL {
        directory.appendingPathComponent("\(file.name).etag")
    }

    /// Returns the downloaded file, staged next to the one it would replace, or nil when the server
    /// said it hasn't changed — which still counts as checked now, what `downloadedAt()` reports.
    private func download(_ file: File) async throws -> (url: URL, etag: String?)? {
        let destination = url(for: file)
        var request = URLRequest(url: baseURL.appendingPathComponent(file.name))
        let hasCopy = FileManager.default.fileExists(atPath: destination.path)
        if hasCopy, let etag = try? String(contentsOf: etagURL(for: file), encoding: .utf8) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 304, hasCopy {
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return nil
        }
        guard (200 ... 299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let staging = directory.appendingPathComponent("\(file.name).download")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.moveItem(at: temporary, to: staging)
        return (staging, http.value(forHTTPHeaderField: "ETag"))
    }

    private func decode(formula: URL, cask: URL) async throws -> PackageCatalogIndex {
        let formulae = try await decodeEntries(CatalogFormulaJSON.self, at: formula, file: .formula)
        let casks = try await decodeEntries(CatalogCaskJSON.self, at: cask, file: .cask)
        return PackageCatalogIndex(packages: formulae.map(\.package) + casks.map(\.package))
    }

    /// Skips entries that don't decode — upstream's format isn't ours, and one odd entry shouldn't
    /// cost the other thousands — but refuses a file where more than 1% don't: that's a format
    /// change, not an odd entry, and the catalog would quietly be missing whole kinds of packages.
    private func decodeEntries<Entry: Decodable>(_: Entry.Type, at url: URL, file: File) async throws -> [Entry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoded = try JSONDecoder().decode(LossyArray<Entry>.self, from: data)
        if let error = decoded.firstError {
            await logger.log(
                "PackageCatalog: skipped \(decoded.skipped) of \(decoded.total) entries in \(file.name) — first: \(error)",
                .warn
            )
        }
        guard !decoded.elements.isEmpty, decoded.skipped * 100 <= decoded.total else {
            throw PackageCatalogError.formatChanged(file: file.name, skipped: decoded.skipped, total: decoded.total)
        }
        return decoded.elements
    }
}

enum PackageCatalogError: LocalizedError {
    case formatChanged(file: String, skipped: Int, total: Int)

    var errorDescription: String? {
        switch self {
        case let .formatChanged(file, skipped, total):
            L("Homebrew's catalog changed format: \(skipped) of \(total) entries in \(file) couldn't be read.")
        }
    }
}

/// An array decoded one element at a time, skipping the ones that fail instead of failing whole.
struct LossyArray<Element: Decodable>: Decodable {
    private(set) var elements: [Element] = []
    private(set) var skipped = 0
    private(set) var firstError: Error?

    var total: Int {
        elements.count + skipped
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            do {
                try elements.append(container.decode(Element.self))
            } catch {
                skipped += 1
                firstError = firstError ?? error
                // A failed decode leaves the container on the same element; this steps past it.
                _ = try container.decode(Skipped.self)
            }
        }
    }

    /// Decodes from anything without reading it — only there to move past a bad element.
    private struct Skipped: Decodable {
        init(from _: Decoder) {}
    }
}

/// The catalog, ready to look things up in: built once per download, off the main actor, so a
/// keystroke in the search field only scans precomputed keys.
struct PackageCatalogIndex {
    let packages: [CatalogPackage]
    /// Every name a package answers to, reduced the way `brew search` reduces them.
    private let nameKeys: [[String]]
    private let descKeys: [String]
    private let formulaIndex: [String: Int]
    private let caskIndex: [String: Int]
    /// Aliases and old names (`kubectl` → `kubernetes-cli`), per kind, for lookups by any name
    /// `brew install` would accept.
    private let formulaAliases: [String: Int]
    private let caskAliases: [String: Int]

    init(packages: [CatalogPackage]) {
        self.packages = packages
        nameKeys = packages.map { package in
            ([package.name, package.displayName] + package.aliases).map(LocalPackageIndex.simplify)
        }
        descKeys = packages.map { $0.desc?.lowercased() ?? "" }
        var formulae: [String: Int] = [:]
        var casks: [String: Int] = [:]
        var formulaAliases: [String: Int] = [:]
        var caskAliases: [String: Int] = [:]
        for (index, package) in packages.enumerated() {
            if package.isCask {
                casks[package.name] = index
                for alias in package.aliases {
                    caskAliases[alias] = caskAliases[alias] ?? index
                }
            } else {
                formulae[package.name] = index
                for alias in package.aliases {
                    formulaAliases[alias] = formulaAliases[alias] ?? index
                }
            }
        }
        formulaIndex = formulae
        caskIndex = casks
        self.formulaAliases = formulaAliases
        self.caskAliases = caskAliases
        apps = packages.filter(\.isApp)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        self.formulae = packages.filter { !$0.isCask }.sorted { $0.name < $1.name }
    }

    /// Every formula, by name — built once here, not filtered on every render.
    let formulae: [CatalogPackage]
    /// Casks that install an app, by name — fonts, drivers and the like are left to search.
    let apps: [CatalogPackage]

    /// Takes a bare name or one qualified with an official tap (`homebrew/cask/firefox`). A name
    /// from any other tap isn't in this catalog, even when an official package shares its last part.
    func package(named name: String, isCask: Bool) -> CatalogPackage? {
        let parts = name.split(separator: "/")
        if parts.count == 3, !["homebrew/core", "homebrew/cask"].contains("\(parts[0])/\(parts[1])".lowercased()) {
            return nil
        }
        let bare = String(parts.last ?? Substring(name))
        let index = isCask ? caskIndex[bare] ?? caskAliases[bare] : formulaIndex[bare] ?? formulaAliases[bare]
        return index.map { packages[$0] }
    }

    /// Names first (exact, then prefix, then anywhere), then descriptions; ties go to the more
    /// popular package. Same matching as `brew search --desc`, without starting brew.
    func search(_ query: String, popularity: (CatalogPackage) -> Int = { _ in 0 }) -> [CatalogPackage] {
        let needle = LocalPackageIndex.simplify(query)
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !needle.isEmpty else { return [] }
        var ranked: [(rank: Int, package: CatalogPackage)] = []
        for (index, package) in packages.enumerated() {
            let keys = nameKeys[index]
            let rank: Int? = if keys.contains(needle) {
                0
            } else if keys.contains(where: { $0.hasPrefix(needle) }) {
                1
            } else if keys.contains(where: { $0.contains(needle) }) {
                2
            } else if !words.isEmpty, words.allSatisfy({ descKeys[index].contains($0) }) {
                3
            } else {
                nil
            }
            if let rank { ranked.append((rank, package)) }
        }
        return ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            let (left, right) = (popularity(lhs.package), popularity(rhs.package))
            return left != right ? left > right : lhs.package.name < rhs.package.name
        }
        .map(\.package)
    }
}
