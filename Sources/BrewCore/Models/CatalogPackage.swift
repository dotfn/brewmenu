import Foundation

/// One formula or cask from Homebrew's full catalog (formulae.brew.sh's `formula.json` /
/// `cask.json`) — everything that can be installed from homebrew/core and homebrew/cask, not just
/// what is installed. Only the fields the app shows are kept: the two files are ~50 MB together.
public struct CatalogPackage: Identifiable, Hashable, Sendable {
    /// The formula name or cask token — what `brew install` takes.
    public let name: String
    /// What a person would call it: a cask's first `name` ("Visual Studio Code"), else `name`.
    public let displayName: String
    public let desc: String?
    public let version: String
    public let homepage: String?
    public let isCask: Bool
    public let tap: String
    public let deprecated: Bool
    public let disabled: Bool
    /// Other names `brew install` accepts for it (formula aliases and old names, old cask tokens).
    public let aliases: [String]
    /// Where the cask puts its app, e.g. `/Applications/Visual Studio Code.app` — nil for
    /// formulae and for casks that install no app (fonts, drivers, command-line tools).
    public let appPath: String?

    public var id: String {
        "\(isCask ? "cask" : "formula"):\(name)"
    }

    /// A cask with an app in it — what the "Apps" section lists.
    public var isApp: Bool {
        appPath != nil
    }

    public init(
        name: String,
        displayName: String? = nil,
        desc: String?,
        version: String,
        homepage: String? = nil,
        isCask: Bool,
        tap: String? = nil,
        deprecated: Bool = false,
        disabled: Bool = false,
        aliases: [String] = [],
        appPath: String? = nil
    ) {
        self.name = name
        self.displayName = displayName ?? name
        self.desc = desc
        self.version = version
        self.homepage = homepage
        self.isCask = isCask
        self.tap = tap ?? (isCask ? "homebrew/cask" : "homebrew/core")
        self.deprecated = deprecated
        self.disabled = disabled
        self.aliases = aliases
        self.appPath = appPath
    }
}

// MARK: - formulae.brew.sh decoding

/// `brew info --json=v2 <names>`: the same shapes as formulae.brew.sh's catalog, for packages it
/// doesn't index — a third-party tap's.
public struct BrewInfoCatalogOutput: Decodable, Sendable {
    public let formulae: [CatalogFormulaJSON]
    public let casks: [CatalogCaskJSON]

    public var packages: [CatalogPackage] {
        formulae.map(\.qualifiedPackage) + casks.map(\.qualifiedPackage)
    }
}

/// One entry of `/api/formula.json`, decoded only as far as `CatalogPackage` needs.
public struct CatalogFormulaJSON: Decodable, Sendable {
    struct Versions: Decodable {
        let stable: String?
    }

    let name: String
    /// `user/repo/name` outside homebrew/core; the bare name in it.
    let fullName: String?
    let tap: String?
    let desc: String?
    let homepage: String?
    let versions: Versions
    let aliases: [String]?
    let oldnames: [String]?
    let deprecated: Bool?
    let disabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case name, tap, desc, homepage, versions, aliases, oldnames, deprecated, disabled
        case fullName = "full_name"
    }

    public var package: CatalogPackage {
        package(named: name)
    }

    /// Named the way brew needs it from outside homebrew/core (`user/repo/name`), so installing it
    /// can't pick an official package that shares the bare name.
    public var qualifiedPackage: CatalogPackage {
        package(named: fullName ?? name)
    }

    private func package(named qualified: String) -> CatalogPackage {
        CatalogPackage(
            name: qualified,
            // The bare name: `user/repo/` is for brew, not for reading.
            displayName: name,
            desc: desc,
            version: versions.stable ?? "",
            homepage: homepage,
            isCask: false,
            tap: tap,
            deprecated: deprecated ?? false,
            disabled: disabled ?? false,
            aliases: (aliases ?? []) + (oldnames ?? [])
        )
    }
}

/// One entry of `/api/cask.json`, decoded only as far as `CatalogPackage` needs.
public struct CatalogCaskJSON: Decodable, Sendable {
    /// One element of `artifacts`: a single-key object (`{"app": [...], "target": ...}`,
    /// `{"zap": [...]}`, …). Only `app` matters here. formulae.brew.sh adds `target`, the app's
    /// final path (renames included); inside `app`, items are the file name and, for a renamed
    /// app, `{"target": "New Name.app"}`.
    struct Artifact: Decodable {
        enum Item: Decodable {
            case path(String)
            case renamed(String)
            case other

            private struct Options: Decodable {
                let target: String?
            }

            /// Not one of the two shapes above means nothing about where the app goes — `.other`,
            /// not an error that would cost the whole cask.
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let path = try? container.decode(String.self) {
                    self = .path(path)
                } else if let target = (try? container.decode(Options.self))?.target {
                    self = .renamed(target)
                } else {
                    self = .other
                }
            }
        }

        let app: [Item]?
        let target: String?
    }

    let token: String
    /// `user/repo/token` outside homebrew/cask; the bare token in it.
    let fullToken: String?
    let tap: String?
    let name: [String]?
    let desc: String?
    let homepage: String?
    let version: String?
    let oldTokens: [String]?
    let deprecated: Bool?
    let disabled: Bool?
    let artifacts: [Artifact]?

    private enum CodingKeys: String, CodingKey {
        case token, tap, name, desc, homepage, version, deprecated, disabled, artifacts
        case oldTokens = "old_tokens"
        case fullToken = "full_token"
    }

    public var package: CatalogPackage {
        package(named: token)
    }

    /// See `CatalogFormulaJSON.qualifiedPackage`.
    public var qualifiedPackage: CatalogPackage {
        package(named: fullToken ?? token)
    }

    private func package(named qualified: String) -> CatalogPackage {
        CatalogPackage(
            name: qualified,
            displayName: name?.first ?? token,
            desc: desc,
            version: version ?? "",
            homepage: homepage,
            isCask: true,
            tap: tap,
            deprecated: deprecated ?? false,
            disabled: disabled ?? false,
            aliases: oldTokens ?? [],
            appPath: appPath
        )
    }

    private var appPath: String? {
        guard let artifact = artifacts?.first(where: { $0.app != nil }) else { return nil }
        // `target` renames the app on install; relative ones are relative to /Applications.
        if let target = artifact.target, target.hasSuffix(".app") {
            return target.hasPrefix("/") ? target : "/Applications/\(target)"
        }
        let items = artifact.app ?? []
        for case let .renamed(target) in items {
            return target.hasPrefix("/") ? target : "/Applications/\(target)"
        }
        for case let .path(file) in items {
            return "/Applications/\((file as NSString).lastPathComponent)"
        }
        return nil
    }
}
