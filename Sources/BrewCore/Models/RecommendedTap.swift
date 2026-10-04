import Foundation

/// A reputable, community-popular third-party tap the user can enable in one click.
/// Seeded from the bundled `RecommendedTaps.json` — a static, curated starting set
/// (mirrors `InstallPack`'s relationship to `InstallPacks.json`), not a live catalog.
public struct RecommendedTap: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let tapName: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let notablePackages: [RecommendedTapPackage]

    /// GitHub repo backing this tap — see `Tap.repositoryURL` for the derivation.
    public var repositoryURL: URL? {
        Tap(name: tapName).repositoryURL
    }

    public init(
        id: String,
        tapName: String,
        title: String,
        subtitle: String,
        systemImage: String,
        notablePackages: [RecommendedTapPackage]
    ) {
        self.id = id
        self.tapName = tapName
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.notablePackages = notablePackages
    }
}

/// One formula/cask a `RecommendedTap` offers, with a link to *its own* project page —
/// unlike the tap's `repositoryURL`, this can't be derived (a tap repo just holds
/// formula definitions; each package it builds is its own separate project, often
/// hosted somewhere else entirely, e.g. `koekeishiya/formulae`'s `yabai` formula
/// builds the `asmvik/yabai` project). Stored, and curated/verified by hand.
public struct RecommendedTapPackage: Codable, Identifiable, Equatable, Sendable {
    public let name: String
    public let url: URL?
    public var id: String {
        name
    }

    public init(
        name: String,
        url: URL?
    ) {
        self.name = name
        self.url = url
    }
}
