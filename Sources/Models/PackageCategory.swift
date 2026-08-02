import Foundation

/// Homebrew has no official category taxonomy for formulae or casks — this is a
/// best-effort keyword classifier over each package's name + description, not an
/// authoritative source. It's applied only to *installed* packages (a few dozen at
/// most), where being approximately right is useful; it deliberately isn't applied to
/// the full Homebrew catalog (tens of thousands of entries), where the same heuristic
/// would be far noisier and unmaintainable.
enum PackageCategory: String, CaseIterable, Hashable, Identifiable {
    case cloudInfrastructure, data, developerTools, games, languageRuntime
    case media, networking, other, productivity, science, security, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloudInfrastructure: L("Cloud Infrastructure")
        case .data: L("Data")
        case .developerTools: L("Developer Tools")
        case .games: L("Games")
        case .languageRuntime: L("Language Runtime")
        case .media: L("Media")
        case .networking: L("Networking")
        case .other: L("Other")
        case .productivity: L("Productivity")
        case .science: L("Science")
        case .security: L("Security")
        case .system: L("System")
        }
    }

    var systemImage: String {
        switch self {
        case .cloudInfrastructure: "cloud"
        case .data: "doc.text"
        case .developerTools: "chevron.left.forwardslash.chevron.right"
        case .games: "gamecontroller"
        case .languageRuntime: "curlybraces"
        case .media: "play.rectangle"
        case .networking: "network"
        case .other: "ellipsis"
        case .productivity: "person.2"
        case .science: "atom"
        case .security: "shield"
        case .system: "gearshape.2"
        }
    }

    /// Every category, in the fixed display order used across the sidebar and Categories view.
    static let displayOrder: [PackageCategory] = [
        .cloudInfrastructure, .data, .developerTools, .games, .languageRuntime,
        .media, .networking, .other, .productivity, .science, .security, .system,
    ]

    /// Known language/runtime formula base names (version suffixes like "@3.13" are
    /// stripped before matching). Checked by *name*, not description — matching on
    /// "rust" or "go" appearing anywhere in a description misclassifies any tool
    /// merely *written in* that language (e.g. "warp — Rust-based terminal" is a
    /// terminal app, not a language runtime) as often as it correctly catches one.
    private static let runtimeNames: Set<String> = [
        "python", "node", "ruby", "go", "rust", "rustup", "perl", "php", "lua",
        "julia", "elixir", "erlang", "openjdk", "java", "dotnet", "deno", "bun",
    ]

    /// Ordered (category, keywords) rules — first match wins, so more specific
    /// categories are listed before "Developer Tools", which would otherwise catch
    /// almost every CLI formula via generic words like "tool" or "library".
    private static let rules: [(PackageCategory, [String])] = [
        (.security, ["ssl", "tls", "gnupg", "gpg", "encrypt", "certificate", "password", "vulnerab", "firewall", "security"]),
        (.cloudInfrastructure, ["docker", "kubernetes", "k8s", "terraform", "ansible", "vagrant", "helm", " aws ", "amazon web services", "google cloud", "azure", "cloud-native", "container orchestrat"]),
        (.data, ["database", " sql", "redis", "mongo", "postgres", "sqlite", "mysql", "elasticsearch", "kafka", "data store", " orm "]),
        (.languageRuntime, ["programming language", "interpreter", "compiler for", "runtime for", "runtime environment", "runtime manager"]),
        (.networking, ["http", " dns", "proxy", " vpn", " ssh", " ftp", "network", "socket", "file transfer", "download"]),
        (.media, ["video", "audio", "image processing", "photo", "media", "codec", "streaming", "music"]),
        (.science, ["scientific", "numerical", "machine learning", "statistic", "data science", "neural network", "linear algebra"]),
        (.games, ["game", "gaming", "emulator"]),
        (.productivity, ["note-taking", "calendar", "task management", "to-do", "office suite"]),
        (.system, ["system monitor", "process monitor", "file manager", "backup", "disk usage", "system utilit"]),
        (.developerTools, [
            "command-line", "command line", "cli ", "clis", "developer", "development", "coding",
            "sdk", "framework", "build tool", "version control", "revision control", "compiler",
            "editor", "ide ", "debug", "linter", "package manager", "library for", "toolkit",
        ]),
    ]

    /// Best-effort classification from a package's name and description.
    static func classify(name: String, desc: String?) -> PackageCategory {
        let baseName = name.split(separator: "@").first.map { $0.lowercased() } ?? name.lowercased()
        if runtimeNames.contains(baseName) { return .languageRuntime }

        let haystack = " \(name.lowercased()) \((desc ?? "").lowercased()) "
        for (category, keywords) in rules {
            if keywords.contains(where: { haystack.contains($0) }) {
                return category
            }
        }
        return .other
    }
}

extension InstalledPackage {
    var category: PackageCategory { PackageCategory.classify(name: name, desc: desc) }
}
