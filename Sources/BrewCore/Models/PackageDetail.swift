import Foundation

/// Rich, on-demand detail for a single formula/cask — fetched from formulae.brew.sh's
/// per-package endpoint (`formula/<name>.json` / `cask/<token>.json`), which already
/// embeds deprecation/disable status and 30/90/365-day install analytics. One small
/// request per package looked-up, not the full ~48MB catalog.
public struct PackageDetail: Equatable, Codable, Sendable {
    public let name: String
    public let isCask: Bool
    public let desc: String?
    public let homepage: String?
    public let version: String?
    public let requirements: [String]

    public let deprecated: Bool
    public let deprecationReason: String?
    public let disabled: Bool
    public let disableDate: String?

    public let installs30d: Int?
    public let installs90d: Int?
    public let installs365d: Int?

    public var installCommand: String {
        isCask ? "brew install --cask \(name)" : "brew install \(name)"
    }

    public init(
        name: String,
        isCask: Bool,
        desc: String?,
        homepage: String?,
        version: String?,
        requirements: [String],
        deprecated: Bool,
        deprecationReason: String?,
        disabled: Bool,
        disableDate: String?,
        installs30d: Int?,
        installs90d: Int?,
        installs365d: Int?
    ) {
        self.name = name
        self.isCask = isCask
        self.desc = desc
        self.homepage = homepage
        self.version = version
        self.requirements = requirements
        self.deprecated = deprecated
        self.deprecationReason = deprecationReason
        self.disabled = disabled
        self.disableDate = disableDate
        self.installs30d = installs30d
        self.installs90d = installs90d
        self.installs365d = installs365d
    }
}

// MARK: - formulae.brew.sh decoding

/// Wrapper for `/api/formula/<name>.json` and `/api/cask/<token>.json`. Both carry the
/// same fields this app cares about; only the name/version keys differ (`name`/`versions.stable`
/// for formulae, `token`/`version` for casks).
public struct PackageDetailJSON: Decodable, Sendable {
    public struct Analytics: Decodable, Sendable {
        public struct Install: Decodable, Sendable {
            let d30: [String: Int]?
            let d90: [String: Int]?
            let d365: [String: Int]?
            enum CodingKeys: String, CodingKey {
                case d30 = "30d", d90 = "90d", d365 = "365d"
            }
        }

        public let install: Install?
    }

    public struct Versions: Decodable, Sendable { let stable: String? }
    public struct Requirement: Decodable, Sendable { let name: String? }

    public let desc: String?
    public let homepage: String?
    public let version: String? // casks
    public let versions: Versions? // formulae
    public let deprecated: Bool?
    public let deprecationReason: String?
    public let disabled: Bool?
    public let disableDate: String?
    public let requirements: [Requirement]?
    public let analytics: Analytics?

    public func detail(requestedName: String, isCask: Bool) -> PackageDetail {
        PackageDetail(
            name: requestedName,
            isCask: isCask,
            desc: desc,
            homepage: homepage,
            version: version ?? versions?.stable,
            requirements: (requirements ?? []).compactMap(\.name),
            deprecated: deprecated ?? false,
            deprecationReason: deprecationReason,
            disabled: disabled ?? false,
            disableDate: disableDate,
            installs30d: analytics?.install?.d30?[requestedName],
            installs90d: analytics?.install?.d90?[requestedName],
            installs365d: analytics?.install?.d365?[requestedName]
        )
    }
}
