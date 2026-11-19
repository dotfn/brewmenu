import BrewCore
import Foundation

/// Searches package names without starting brew. Homebrew already keeps the full list of
/// official names on disk (`formula_names.txt` / `cask_names.txt`, refreshed by its own API
/// fetches), and a third-party tap's names are its file names. `brew search` reads the same
/// data, but pays Ruby's startup twice per query (formulae, then casks).
///
/// It answers only what it can answer exactly: `search` returns `nil` when the lists aren't
/// there or the query is a `/regex/`, and the caller asks brew instead.
struct LocalPackageIndex {
    /// Homebrew's API cache folder, `<HOMEBREW_CACHE>/api`.
    let apiDirectory: URL

    private static let officialTaps: Set<String> = ["homebrew/core", "homebrew/cask"]

    static var homebrewDefault: LocalPackageIndex {
        let cache = ProcessInfo.processInfo.environment["HOMEBREW_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Homebrew")
        return LocalPackageIndex(apiDirectory: cache.appendingPathComponent("api"))
    }

    /// When Homebrew last fetched its package data — the newest file in its API cache. `brew update`
    /// refreshes it, and so does brew's own auto-update when someone installs from Terminal.
    func lastFetchDate() -> Date? {
        let fileManager = FileManager.default
        return [apiDirectory, apiDirectory.appendingPathComponent("internal")]
            .flatMap { (try? fileManager.contentsOfDirectory(
                at: $0,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? [] }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    /// `repository` is `HOMEBREW_REPOSITORY`, where the taps are cloned.
    func search(_ query: String, repository: String?) -> [SearchResult]? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !(trimmed.hasPrefix("/") && trimmed.hasSuffix("/")) else { return nil }
        guard let formulae = names(in: "formula_names.txt"), let casks = names(in: "cask_names.txt") else {
            return nil
        }
        let needle = Self.simplify(trimmed)
        guard !needle.isEmpty else { return [] }
        let tapped = repository.map(Self.tapPackages) ?? []
        return (formulae.map { SearchResult(name: $0, isCask: false) }
            + casks.map { SearchResult(name: $0, isCask: true) }
            + tapped)
            .filter { Self.simplify($0.name).contains(needle) }
    }

    /// Same reduction `brew search` applies to both sides before comparing
    /// (`Homebrew::Search.simplify_string`): case and punctuation don't count.
    static func simplify(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "@" || $0 == "+"
        }.map(Character.init))
    }

    private func names(in file: String) -> [String]? {
        guard let text = try? String(contentsOf: apiDirectory.appendingPathComponent(file), encoding: .utf8) else {
            return nil
        }
        let names = text.split(separator: "\n").map(String.init)
        return names.isEmpty ? nil : names
    }

    /// Every formula and cask of the third-party taps cloned under `repository`, named the way
    /// `brew search` prints them: `user/repo/name`.
    static func tapPackages(repository: String) -> [SearchResult] {
        let fileManager = FileManager.default
        let tapsRoot = URL(fileURLWithPath: repository).appendingPathComponent("Library/Taps")
        var results: [SearchResult] = []
        for user in (try? fileManager.contentsOfDirectory(atPath: tapsRoot.path)) ?? [] {
            let userDirectory = tapsRoot.appendingPathComponent(user)
            for folder in (try? fileManager.contentsOfDirectory(atPath: userDirectory.path)) ?? []
                where folder.hasPrefix("homebrew-")
            {
                let tap = "\(user)/\(folder.dropFirst("homebrew-".count))"
                guard !officialTaps.contains(tap.lowercased()) else { continue }
                let directory = userDirectory.appendingPathComponent(folder)
                // Homebrew's own precedence for where a tap keeps its formulae.
                let formulaDirectory = ["Formula", "HomebrewFormula"]
                    .map { directory.appendingPathComponent($0) }
                    .first { fileManager.fileExists(atPath: $0.path) }
                let formulae = formulaDirectory.map { rubyFiles(under: $0, recursive: true) }
                    ?? rubyFiles(under: directory, recursive: false)
                let casks = rubyFiles(under: directory.appendingPathComponent("Casks"), recursive: true)
                results += formulae.map { SearchResult(name: "\(tap)/\($0)", isCask: false) }
                results += casks.map { SearchResult(name: "\(tap)/\($0)", isCask: true) }
            }
        }
        return results.sorted { $0.name < $1.name }
    }

    private static func rubyFiles(under directory: URL, recursive: Bool) -> [String] {
        let options: FileManager.DirectoryEnumerationOptions = recursive
            ? [.skipsHiddenFiles]
            : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: options
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "rb" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
}
