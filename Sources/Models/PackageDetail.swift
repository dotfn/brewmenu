import Foundation

/// Rich, on-demand detail for a single formula/cask — fetched from formulae.brew.sh's
/// per-package endpoint (`formula/<name>.json` / `cask/<token>.json`), which already
/// embeds deprecation/disable status and 30/90/365-day install analytics. One small
/// request per package looked-up, not the full ~48MB catalog.
struct PackageDetail: Sendable, Equatable, Codable {
    let name: String
    let isCask: Bool
    let desc: String?
    let homepage: String?
    let version: String?
    let requirements: [String]

    let deprecated: Bool
    let deprecationReason: String?
    let disabled: Bool
    let disableDate: String?

    let installs30d: Int?
    let installs90d: Int?
    let installs365d: Int?

    var installCommand: String {
        isCask ? "brew install --cask \(name)" : "brew install \(name)"
    }
}

// MARK: - formulae.brew.sh decoding

/// Wrapper for `/api/formula/<name>.json` and `/api/cask/<token>.json`. Both carry the
/// same fields this app cares about; only the name/version keys differ (`name`/`versions.stable`
/// for formulae, `token`/`version` for casks).
struct PackageDetailJSON: Decodable {
    struct Analytics: Decodable {
        struct Install: Decodable {
            let d30: [String: Int]?
            let d90: [String: Int]?
            let d365: [String: Int]?
            enum CodingKeys: String, CodingKey {
                case d30 = "30d", d90 = "90d", d365 = "365d"
            }
        }
        let install: Install?
    }
    struct Versions: Decodable { let stable: String? }
    struct Requirement: Decodable { let name: String? }

    let desc: String?
    let homepage: String?
    let version: String?           // casks
    let versions: Versions?        // formulae
    let deprecated: Bool?
    let deprecationReason: String?
    let disabled: Bool?
    let disableDate: String?
    let requirements: [Requirement]?
    let analytics: Analytics?

    enum CodingKeys: String, CodingKey {
        case desc, homepage, version, versions
        case deprecated
        case deprecationReason = "deprecation_reason"
        case disabled
        case disableDate = "disable_date"
        case requirements
        case analytics
    }

    func detail(requestedName: String, isCask: Bool) -> PackageDetail {
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
