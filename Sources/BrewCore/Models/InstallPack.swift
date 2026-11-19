import Foundation

/// A curated collection of formulae/casks — browsed like an App Store category, and installable in
/// one action. Seeded from the bundled `InstallPacks.json`: Homebrew itself has no categories.
public struct InstallPack: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let formulae: [String]
    public let casks: [String]

    public var packageCount: Int {
        formulae.count + casks.count
    }

    /// Titles and subtitles are translated in Localizable.strings, keyed by their English text.
    public var localizedTitle: String {
        L(String.LocalizationValue(title))
    }

    public var localizedSubtitle: String {
        L(String.LocalizationValue(subtitle))
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
