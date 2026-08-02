import Foundation

/// A reputable, community-popular third-party tap the user can enable in one click.
/// Seeded from the bundled `RecommendedTaps.json` — a static, curated starting set
/// (mirrors `InstallPack`'s relationship to `InstallPacks.json`), not a live catalog.
struct RecommendedTap: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let tapName: String
    let title: String
    let subtitle: String
    let systemImage: String
    let notablePackages: [RecommendedTapPackage]

    /// GitHub repo backing this tap — see `Tap.repositoryURL` for the derivation.
    var repositoryURL: URL? { Tap(name: tapName).repositoryURL }
}

/// One formula/cask a `RecommendedTap` offers, with a link to *its own* project page —
/// unlike the tap's `repositoryURL`, this can't be derived (a tap repo just holds
/// formula definitions; each package it builds is its own separate project, often
/// hosted somewhere else entirely, e.g. `koekeishiya/formulae`'s `yabai` formula
/// builds the `asmvik/yabai` project). Stored, and curated/verified by hand.
struct RecommendedTapPackage: Codable, Sendable, Identifiable, Equatable {
    let name: String
    let url: URL?
    var id: String { name }
}
