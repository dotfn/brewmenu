import Foundation

/// An AI chat that can be opened with a question already written in — for a `brew doctor` finding
/// or a failed command, when the fix isn't obvious. Nothing is sent from here: the question goes in
/// the link, and the user reads it before sending (Claude's app asks for that; ChatGPT may send it
/// on its own).
public enum AIAssistant: String, CaseIterable, Identifiable, Sendable {
    case claude, chatGPT

    public var id: String {
        rawValue
    }

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        }
    }

    /// The link that opens a new chat with `prompt` in it.
    ///
    /// - Claude: `claude://claude.ai/new?q=` when its desktop app is installed — Anthropic's
    ///   documented link, which fills the prompt in for review. Otherwise the web's
    ///   `https://claude.ai/new?q=`, which isn't documented and may open an empty chat.
    /// - ChatGPT: `https://chatgpt.com/?q=` — not documented by OpenAI either.
    ///
    /// The caller also copies the prompt, for the cases where it doesn't come through.
    public func url(asking prompt: String, claudeAppInstalled: Bool) -> URL? {
        let base = switch self {
        case .claude: claudeAppInstalled ? "claude://claude.ai/new?q=" : "https://claude.ai/new?q="
        case .chatGPT: "https://chatgpt.com/?q="
        }
        guard let query = prompt.addingPercentEncoding(withAllowedCharacters: Self.unreserved) else { return nil }
        return URL(string: base + query)
    }

    /// RFC 3986's unreserved characters, ASCII only: everything else — `&`, `+`, `=`, `#`, line
    /// breaks, accented letters — is percent-encoded, so no part of the prompt reads as URL syntax.
    private static let unreserved = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
}

/// The questions BrewMenu writes for an AI assistant. They say what the system is (an answer for
/// Intel or an older macOS is a different answer), quote what Homebrew said, and ask for the fix.
public enum AIPrompt {
    /// Well under Claude's documented ~14,000 characters, and short enough for a link any browser
    /// and server takes: a long log is cut in the middle, keeping its start (what ran) and its end
    /// (how it failed).
    public static let maxQuotedLength = 4000

    /// What's asked about a `brew doctor` finding.
    public static func doctorFinding(_ warning: DoctorWarning, system: String, homeDirectory: String) -> String {
        let quoted = quote(warning.message, homeDirectory: homeDirectory)
        return """
        \(L("I use Homebrew on \(system). brew doctor reports this:"))

        \(quoted)

        \(L("What does it mean, is it safe to ignore, and how do I fix it step by step?"))
        """
    }

    /// What's asked about a brew command that failed — `details` as "Copy error" puts it: the
    /// command, its exit code and Homebrew's output.
    public static func failedCommand(_ details: String, system: String, homeDirectory: String) -> String {
        let quoted = quote(details, homeDirectory: homeDirectory)
        return """
        \(L("I use Homebrew on \(system). This command failed:"))

        \(quoted)

        \(L("What went wrong, and how do I fix it?"))
        """
    }

    /// "macOS 26.1, Apple silicon".
    public static func systemDescription(
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        #if arch(arm64)
            let chip = "Apple silicon"
        #else
            let chip = "Intel"
        #endif
        let number = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        return "macOS \(number), \(chip)"
    }

    /// The home folder as `~` — it names the user, and the answer doesn't need it — and the middle
    /// of a text past `maxQuotedLength` dropped.
    static func quote(_ text: String, homeDirectory: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !homeDirectory.isEmpty, homeDirectory != "/" {
            text = text.replacingOccurrences(of: homeDirectory, with: "~")
        }
        guard text.count > maxQuotedLength else { return text }
        let head = text.prefix(maxQuotedLength / 3)
        let tail = text.suffix(maxQuotedLength - head.count - 3)
        return "\(head)\n…\n\(tail)"
    }
}
