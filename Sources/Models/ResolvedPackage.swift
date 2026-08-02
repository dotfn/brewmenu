import Foundation

/// The result of looking up a formula/cask name (bare or fully-qualified, e.g.
/// `wget` or `user/repo/name`) via `brew info --json=v2`, before actually installing
/// it — lets the "Add" flow tell the user whether it found a formula or a cask, and
/// in which tap, so they can confirm before anything is installed.
struct ResolvedPackage: Sendable, Equatable {
    let name: String
    let tap: String
    let desc: String?
    let isCask: Bool
    /// Whether resolving this required tapping its repo first — `brew info`, unlike
    /// `brew install`, doesn't auto-tap on its own, so the lookup had to `brew tap` the
    /// repo before it could succeed. Surfaced so a "just looking it up" step doesn't
    /// silently change the user's Homebrew setup without telling them.
    var didAutoTap: Bool = false
}

extension BrewInfoInstalledOutput {
    /// The first formula or cask this lookup matched, if any — `brew info --json=v2
    /// <name>` returns the same `{formulae, casks}` shape as `--installed`, just
    /// scoped to whatever name was requested instead of everything installed.
    func firstResolvedPackage(didAutoTap: Bool = false) -> ResolvedPackage? {
        if let f = formulae.first {
            return ResolvedPackage(name: f.name, tap: f.tap ?? "homebrew/core", desc: f.desc, isCask: false, didAutoTap: didAutoTap)
        }
        if let c = casks.first {
            return ResolvedPackage(name: c.token, tap: c.tap ?? "homebrew/cask", desc: c.desc, isCask: true, didAutoTap: didAutoTap)
        }
        return nil
    }
}
