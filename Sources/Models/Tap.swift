import Foundation

struct Tap: Codable, Sendable, Hashable, Identifiable {
    let name: String
    var id: String { name }

    /// Display name for built-in taps (drops the "homebrew/" prefix); third-party
    /// taps show their full "user/repo" form since there's no shorter canonical name.
    var displayName: String {
        name.hasPrefix("homebrew/") ? String(name.dropFirst("homebrew/".count)).capitalized : name
    }

    /// Whether this is one of Homebrew's own built-in taps (homebrew/core, homebrew/cask)
    /// rather than a third-party tap someone explicitly added.
    var isOfficial: Bool { name.hasPrefix("homebrew/") }

    /// GitHub repo backing this tap — derived, not stored: Homebrew requires every
    /// `user/repo` tap (including its own homebrew/core and homebrew/cask) to live at
    /// `github.com/user/homebrew-repo` for its default tap resolution to work at all.
    var repositoryURL: URL? {
        let parts = name.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return URL(string: "https://github.com/\(parts[0])/homebrew-\(parts[1])")
    }
}

/// `brew tap-info --json=v1 <tap>` response — every formula/cask a tap makes
/// available, not just the ones currently installed from it.
struct TapInfoOutput: Decodable {
    let formulaNames: [String]
    let caskTokens: [String]
}
