import Foundation

/// One `brew doctor` finding. `brew doctor --json` hands each one over in parts — the problem, the
/// suggested fix, the commands that fix it, the packages and pages it's about — and they're kept
/// apart here so the Doctor page can show the fix as something to act on. Joined into one message
/// and cut at three lines, the fix was usually the part nobody got to see. The older text output
/// only gives `message`; the parts are then worked out from it.
public struct DoctorWarning: Codable, Identifiable, Equatable, Sendable {
    public enum Severity: String, Codable, Equatable, Sendable { case warning, error }
    public let severity: Severity
    /// The whole finding as `brew doctor` prints it, "Warning: …" followed by its fix — what history
    /// stores and notifications show.
    public let message: String
    /// The problem alone: no "Warning:" prefix, no fix.
    public let finding: String
    /// The suggested fix as brew words it. Its commands and links are also in `commands`/`links`.
    public let remediation: String?
    /// Commands the fix asks for: brew's own list, plus the ones its prose shows on a line of their
    /// own — most checks leave the list empty and write the command into the text.
    public let commands: [String]
    /// Packages the finding is about.
    public let affectedPackages: [String]
    public let links: [URL]

    /// The finding's first sentence, on one line.
    public let title: String
    /// The rest of the finding, rewrapped. Nil when the title is all there is.
    public let detail: String?
    /// The fix, step by step in brew's own order: its prose, and each command and address where
    /// the prose puts it. Pulled out of the prose and listed after it, a command read as the
    /// target of whatever sentence happened to end the fix ("…see:").
    public let fixSteps: [FixStep]

    public enum FixStep: Hashable, Sendable {
        case text(String)
        case command(String)
        case link(URL)
    }

    public var id: String {
        message
    }

    /// PATH checks describe the environment BrewMenu runs brew in, which isn't the user's shell.
    /// The word alone: LIBRARY_PATH or PKG_CONFIG_PATH findings aren't about it.
    public var concernsPATH: Bool {
        finding.range(of: #"\bPATH\b"#, options: .regularExpression) != nil
    }

    /// From the text output, which doesn't separate the problem from its fix.
    public init(severity: Severity, message: String) {
        let finding = Self.droppingPrefix(message)
        self.init(
            severity: severity,
            message: message,
            finding: finding,
            remediation: nil,
            commands: Self.commands(in: finding),
            affectedPackages: [],
            links: Self.links(in: finding)
        )
    }

    /// From `brew doctor --json`.
    public init(
        severity: Severity = .warning,
        finding: String,
        remediation: String?,
        commands: [String] = [],
        affectedPackages: [String] = [],
        links: [URL] = []
    ) {
        let finding = finding.trimmingCharacters(in: .whitespacesAndNewlines)
        let remediation = remediation?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fix = remediation?.isEmpty == false ? remediation : nil
        let prefix = severity == .error ? "Error: " : "Warning: "
        self.init(
            severity: severity,
            // Same "Warning: …" shape the text output has, so both paths store the same message.
            message: prefix + [finding, fix].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n\n"),
            finding: finding,
            remediation: fix,
            commands: Self.unique(commands + Self.commands(in: fix ?? "")),
            affectedPackages: Self.unique(affectedPackages),
            links: Self.unique(links + Self.links(in: finding) + Self.links(in: fix ?? ""))
        )
    }

    private init(
        severity: Severity,
        message: String,
        finding: String,
        remediation: String?,
        commands: [String],
        affectedPackages: [String],
        links: [URL]
    ) {
        self.severity = severity
        self.message = message
        self.finding = finding
        self.remediation = remediation
        self.commands = commands
        self.affectedPackages = affectedPackages
        self.links = links
        let (title, rest) = Self.splitTitle(finding)
        self.title = title
        detail = Self.prose(rest, without: commands, links)
        fixSteps = Self.steps(remediation ?? "", commands: commands, links: links)
    }

    private enum CodingKeys: String, CodingKey {
        case severity, message, finding, remediation, commands, affectedPackages, links
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let severity = try c.decode(Severity.self, forKey: .severity)
        let message = try c.decode(String.self, forKey: .message)
        // Saved before the parts were kept: worked out from the message, as for the text output.
        guard let finding = try c.decodeIfPresent(String.self, forKey: .finding) else {
            self.init(severity: severity, message: message)
            return
        }
        try self.init(
            severity: severity,
            message: message,
            finding: finding,
            remediation: c.decodeIfPresent(String.self, forKey: .remediation),
            commands: c.decodeIfPresent([String].self, forKey: .commands) ?? [],
            affectedPackages: c.decodeIfPresent([String].self, forKey: .affectedPackages) ?? [],
            links: c.decodeIfPresent([URL].self, forKey: .links) ?? []
        )
    }

    // MARK: - Reading brew's prose

    private static func droppingPrefix(_ message: String) -> String {
        for prefix in ["Warning: ", "Error: "] where message.hasPrefix(prefix) {
            return String(message.dropFirst(prefix.count))
        }
        return message
    }

    /// The first sentence and what follows it. brew wraps its text at 80 columns, so a sentence
    /// can run over a few lines ("…but you have installed\nformulae that put executables in…").
    private static func splitTitle(_ text: String) -> (title: String, rest: String) {
        let lines = text.components(separatedBy: "\n")
        var titleLines: [String] = []
        for line in lines {
            guard let first = line.first, !first.isWhitespace else { break }
            titleLines.append(line.trimmingCharacters(in: .whitespaces))
            if line.hasSuffix(".") || line.hasSuffix(":") || titleLines.count == 3 { break }
        }
        guard !titleLines.isEmpty else { return (text.trimmingCharacters(in: .whitespacesAndNewlines), "") }
        return (titleLines.joined(separator: " "), lines.dropFirst(titleLines.count).joined(separator: "\n"))
    }

    /// Words a command line starts with in brew's fixes — enough to tell "  brew upgrade x" from
    /// an indented list of package names or certificate authorities.
    private static let commandWords: Set<Substring> = [
        "brew", "sudo", "echo", "printf", "export", "eval", "xcode-select", "softwareupdate",
    ]

    /// Commands shown on an indented line of their own: "  brew upgrade postgresql@18".
    private static func commands(in text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            guard line.first?.isWhitespace == true else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let word = trimmed.split(separator: " ").first, commandWords.contains(word) else { return nil }
            return trimmed
        }
    }

    /// Addresses shown on a line of their own.
    private static func links(in text: String) -> [URL] {
        text.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://"), !trimmed.contains(" ") else {
                return nil
            }
            return URL(string: trimmed)
        }
    }

    /// `text` without the lines that are one of `commands` or `links` (shown as their own controls),
    /// and with brew's 80-column wrap undone: consecutive unindented lines are one paragraph, while
    /// indented lines (lists, commands) and blank lines stay. Nil when nothing is left.
    private static func prose(_ text: String, without commands: [String], _ links: [URL]) -> String? {
        let removed = Set(commands + links.map(\.absoluteString))
        var lines: [String] = []
        var joinsNext = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if removed.contains(trimmed) { continue }
            if trimmed.isEmpty {
                if lines.last?.isEmpty == false { lines.append("") }
                joinsNext = false
                continue
            }
            let isProse = line.first?.isWhitespace == false
            if isProse, joinsNext, let last = lines.popLast() {
                lines.append(last + " " + trimmed)
            } else {
                lines.append(isProse ? trimmed : line)
            }
            joinsNext = isProse && !trimmed.hasSuffix(":")
        }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// `text` cut at its commands and addresses, in order. Commands brew lists without writing them
    /// into the text (and, from the text output, every command — it has no separate fix) follow.
    private static func steps(_ text: String, commands: [String], links: [URL]) -> [FixStep] {
        var steps: [FixStep] = []
        var prose: [String] = []
        func flushProse() {
            if let paragraph = Self.prose(prose.joined(separator: "\n"), without: [], []) {
                steps.append(.text(paragraph))
            }
            prose = []
        }
        let addresses = Dictionary(links.map { ($0.absoluteString, $0) }, uniquingKeysWith: { first, _ in first })
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if commands.contains(trimmed) {
                flushProse()
                steps.append(.command(trimmed))
            } else if let url = addresses[trimmed] {
                flushProse()
                steps.append(.link(url))
            } else {
                prose.append(line)
            }
        }
        flushProse()
        let shown = Set(steps.compactMap { if case let .command(command) = $0 { command } else { nil } })
        return steps + commands.filter { !shown.contains($0) }.map(FixStep.command)
    }

    /// The arguments of a `brew` command BrewMenu can run itself — straight, with no shell between:
    /// `brew upgrade postgresql@18`. Nil for anything else (`sudo …`, a shell profile edit) or for
    /// anything a shell would read differently (quotes, `;`, `>`, `$`), which then stays the
    /// user's to run.
    public static func brewArguments(of command: String) -> [String]? {
        let words = command.split(separator: " ").map(String.init)
        guard words.first == "brew", words.count >= 2 else { return nil }
        let shellSyntax = CharacterSet(charactersIn: "'\"`$;&|<>()*?~\\{}[]!#")
        guard command.rangeOfCharacter(from: shellSyntax) == nil else { return nil }
        return Array(words.dropFirst())
    }

    private static func unique<T: Hashable>(_ items: [T]) -> [T] {
        var seen: Set<T> = []
        return items.filter { seen.insert($0).inserted }
    }
}
