import Foundation

/// A curated bundle of formulae/casks the user can install in one action.
/// Seeded from the bundled `InstallPacks.json` — a static starting set, not a live catalog.
public struct InstallPack: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let formulae: [String]
    public let casks: [String]

    public var packageCount: Int {
        formulae.count + casks.count
    }

    public init(
        id: String,
        title: String,
        subtitle: String,
        systemImage: String,
        formulae: [String],
        casks: [String]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.formulae = formulae
        self.casks = casks
    }
}
