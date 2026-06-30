struct OutdatedPackage: Codable, Sendable, Identifiable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String
    let pinned: Bool
    let isCask: Bool

    var id: String { name }

    init(
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

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
        case pinned
        case isCask = "is_cask"
    }

    // Custom decoder so old snapshots (without "is_cask") still load as formulae.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        installedVersions = try c.decode([String].self, forKey: .installedVersions)
        currentVersion = try c.decode(String.self, forKey: .currentVersion)
        pinned = try c.decode(Bool.self, forKey: .pinned)
        isCask = try c.decodeIfPresent(Bool.self, forKey: .isCask) ?? false
    }
}

// Internal wrapper for the full `brew outdated --json=v2` response.
struct OutdatedCommandOutput: Decodable {
    let formulae: [OutdatedPackage]
    let casks: [OutdatedPackage]
}
