import Foundation

/// A curated bundle of formulae/casks the user can install in one action.
/// Seeded from the bundled `InstallPacks.json` — a static starting set, not a live catalog.
struct InstallPack: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let formulae: [String]
    let casks: [String]

    var packageCount: Int { formulae.count + casks.count }
}
