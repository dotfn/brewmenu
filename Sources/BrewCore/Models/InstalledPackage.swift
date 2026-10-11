import Foundation

/// A formula or cask currently installed, sourced from `brew info --json=v2 --installed`.
public struct InstalledPackage: Identifiable, Equatable, Codable, Sendable {
    public let name: String
    public let tap: String
    public let desc: String?
    public let homepage: String?
    public let version: String
    public let isCask: Bool
    public let pinned: Bool
    public let outdated: Bool
    public let deprecated: Bool
    public let deprecationReason: String?
    public let disabled: Bool
    public let disableReason: String?
    /// Bare names of formulae this package actually links against at runtime, from
    /// brew's own resolved receipt (`installed[].runtime_dependencies`) — not the
    /// formula's *declared* `dependencies`, which also lists build-only and optional
    /// ones that may not even be installed. Empty for casks (brew doesn't report this
    /// for them). Used as a heuristic safety check before uninstalling: not a
    /// guarantee — Homebrew doesn't promise every entry here is still strictly
    /// required — but the same signal `brew uninstall` itself consults before it
    /// would refuse to remove a formula other installed formulae depend on.
    public let runtimeDependencyNames: [String]

    public var id: String {
        name
    }

    public init(
        name: String,
        tap: String,
        desc: String?,
        homepage: String?,
        version: String,
        isCask: Bool,
        pinned: Bool,
        outdated: Bool,
        deprecated: Bool,
        deprecationReason: String?,
        disabled: Bool,
        disableReason: String?,
        runtimeDependencyNames: [String] = []
    ) {
        self.name = name
        self.tap = tap
        self.desc = desc
        self.homepage = homepage
        self.version = version
        self.isCask = isCask
        self.pinned = pinned
        self.outdated = outdated
        self.deprecated = deprecated
        self.deprecationReason = deprecationReason
        self.disabled = disabled
        self.disableReason = disableReason
        self.runtimeDependencyNames = runtimeDependencyNames
    }
}

// MARK: - `brew info --json=v2 --installed` decoding

/// Wrapper for the full `brew info --json=v2 --installed` response.
public struct BrewInfoInstalledOutput: Decodable, Sendable {
    public let formulae: [FormulaJSON]
    public let casks: [CaskJSON]

    public struct FormulaJSON: Decodable, Sendable {
        public struct RuntimeDependency: Decodable, Sendable { let fullName: String }
        public struct Installed: Decodable, Sendable {
            let version: String
            // Absent on ancient `brew` versions' JSON — optional so decoding the rest
            // of the entry doesn't fail over one missing field.
            let runtimeDependencies: [RuntimeDependency]?
        }

        public let name: String
        public let tap: String?
        public let desc: String?
        public let homepage: String?
        public let installed: [Installed]
        public let pinned: Bool
        public let outdated: Bool
        public let deprecated: Bool
        public let deprecationReason: String?
        public let disabled: Bool
        public let disableReason: String?
    }

    public struct CaskJSON: Decodable, Sendable {
        public let token: String
        public let tap: String?
        public let desc: String?
        public let homepage: String?
        public let version: String?
        public let pinned: Bool
        public let outdated: Bool
        public let deprecated: Bool
        public let deprecationReason: String?
        public let disabled: Bool
        public let disableReason: String?
    }

    /// Maps the raw `brew info` shapes into the app's unified `InstalledPackage` model.
    public var installedPackages: [InstalledPackage] {
        let fromFormulae = formulae.map { f in
            InstalledPackage(
                name: f.name,
                tap: f.tap ?? "homebrew/core",
                desc: f.desc,
                homepage: f.homepage,
                version: f.installed.first?.version ?? "?",
                isCask: false,
                pinned: f.pinned,
                outdated: f.outdated,
                deprecated: f.deprecated,
                deprecationReason: f.deprecationReason,
                disabled: f.disabled,
                disableReason: f.disableReason,
                // A dependency in a third-party tap reports as "user/repo/name" here;
                // normalized to the bare name so it matches `InstalledPackage.name`
                // (always bare) regardless of which tap either side came from.
                runtimeDependencyNames: (f.installed.first?.runtimeDependencies ?? []).map {
                    $0.fullName.split(separator: "/").last.map(String.init) ?? $0.fullName
                }
            )
        }
        let fromCasks = casks.map { c in
            InstalledPackage(
                name: c.token,
                tap: c.tap ?? "homebrew/cask",
                desc: c.desc,
                homepage: c.homepage,
                version: c.version ?? "?",
                isCask: true,
                pinned: c.pinned,
                outdated: c.outdated,
                deprecated: c.deprecated,
                deprecationReason: c.deprecationReason,
                disabled: c.disabled,
                disableReason: c.disableReason
            )
        }
        return fromFormulae + fromCasks
    }
}
