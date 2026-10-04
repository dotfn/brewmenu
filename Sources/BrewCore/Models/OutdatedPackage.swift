public struct OutdatedPackage: Codable, Identifiable, Sendable {
    public let name: String
    public let installedVersions: [String]
    public let currentVersion: String
    public let pinned: Bool
    public let isCask: Bool

    public var id: String {
        name
    }

    public init(
        name: String,
        installedVersions: [String],
        currentVersion: String,
        pinned: Bool,
        isCask: Bool = false
    ) {
        self.name = name
        self.installedVersions = installedVersions
        self.currentVersion = currentVersion
        self.pinned = pinned
        self.isCask = isCask
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
        case pinned
        case isCask = "is_cask"
    }

    /// Custom decoder so old snapshots (without "is_cask") still load as formulae.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        installedVersions = try c.decode([String].self, forKey: .installedVersions)
        currentVersion = try c.decode(String.self, forKey: .currentVersion)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        isCask = try c.decodeIfPresent(Bool.self, forKey: .isCask) ?? false
    }
}

/// Internal wrapper for the full `brew outdated --json=v2` response.
public struct OutdatedCommandOutput: Decodable, Sendable {
    public let formulae: [OutdatedPackage]
    public let casks: [OutdatedPackage]

    public init(
        formulae: [OutdatedPackage],
        casks: [OutdatedPackage]
    ) {
        self.formulae = formulae
        self.casks = casks
    }
}
