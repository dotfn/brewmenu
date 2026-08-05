import Foundation

/// A formula or cask currently installed, sourced from `brew info --json=v2 --installed`.
struct InstalledPackage: Sendable, Identifiable, Equatable, Codable {
    let name: String
    let tap: String
    let desc: String?
    let homepage: String?
    let version: String
    let isCask: Bool
    let pinned: Bool
    let outdated: Bool
    let deprecated: Bool
    let deprecationReason: String?
    let disabled: Bool
    let disableReason: String?

    var id: String { name }
}

// MARK: - `brew info --json=v2 --installed` decoding

/// Wrapper for the full `brew info --json=v2 --installed` response.
struct BrewInfoInstalledOutput: Decodable {
    let formulae: [FormulaJSON]
    let casks: [CaskJSON]

    struct FormulaJSON: Decodable {
        struct Installed: Decodable { let version: String }
        let name: String
        let tap: String?
        let desc: String?
        let homepage: String?
        let installed: [Installed]
        let pinned: Bool
        let outdated: Bool
        let deprecated: Bool
        let deprecationReason: String?
        let disabled: Bool
        let disableReason: String?
    }

    struct CaskJSON: Decodable {
        let token: String
        let tap: String?
        let desc: String?
        let homepage: String?
        let version: String?
        let pinned: Bool
        let outdated: Bool
        let deprecated: Bool
        let deprecationReason: String?
        let disabled: Bool
        let disableReason: String?
    }

    /// Maps the raw `brew info` shapes into the app's unified `InstalledPackage` model.
    var installedPackages: [InstalledPackage] {
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
                disableReason: f.disableReason
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
