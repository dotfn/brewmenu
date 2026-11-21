import Foundation

public enum BrewError: Error, Equatable, Sendable {
    case notFound(searchedPaths: [String])
    case notConfigured
    /// `command` is the brew invocation that failed, e.g. "brew upgrade wget". It's diagnostic
    /// context only: `errorDescription` and equality on the message don't depend on it.
    case commandFailed(exitCode: Int32, stderr: String, command: String = "")
    case outputParsingFailed(command: String)
    /// A command that produced no result within its time limit and was stopped. Without a limit a
    /// stalled brew (a tap remote that never answers, say) would hold the caller forever.
    case timedOut(command: String, seconds: Int)
}

public extension BrewError {
    /// The invocation as a user could type it, from brew's argument list.
    static func commandLine(_ arguments: [String]) -> String {
        (["brew"] + arguments).joined(separator: " ")
    }

    /// What "Copy error" puts on the clipboard: the command, its exit code and brew's output, so a
    /// bug report can say exactly what ran. Not localised: it's raw data, meant to be pasted.
    var details: String {
        switch self {
        case let .commandFailed(code, stderr, command):
            let head = command.isEmpty ? "brew" : command
            return "\(head)\nexit code \(code)\n\(Self.withoutProgressNoise(stderr).joined(separator: "\n"))"
        default:
            return localizedDescription
        }
    }
}

// MARK: - Readable output

public extension BrewError {
    /// How many lines of brew's output a message shown in the UI keeps.
    private static let conciseLineLimit = 6

    /// brew's stderr as lines, without what a terminal would have overwritten in place: curl's
    /// download meter repaints (`\r`-separated, "#### 42.3%") and blank lines.
    static func withoutProgressNoise(_ output: String) -> [String] {
        output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                return line.contains { !($0 == "#" || $0 == "=" || $0 == "-" || $0 == "O" || $0 == "%"
                        || $0 == "." || $0 == " " || $0.isNumber) }
            }
    }

    /// The part of a failed command's output worth showing in an alert or a row: brew's own
    /// "Error: …" message when there is one, otherwise the last few lines. The full output stays
    /// available through `details`.
    static func conciseOutput(_ output: String) -> String {
        // "✔︎ Bottle wget (1.25)" — brew ticks off each download on stderr. Those are what went
        // right; shown as the reason for a failure they read as nonsense.
        var all: [String] = []
        for line in withoutProgressNoise(output) where !line.hasPrefix("✔") && line != all.last {
            all.append(line)
        }
        // Same for a tap's deprecation notices, unless they're all there is.
        let withoutNotices = all.filter { !isTapDeprecationNotice($0) }
        let lines = withoutNotices.isEmpty ? all : withoutNotices
        let relevant: ArraySlice<String> = if let first = lines.firstIndex(where: { $0.hasPrefix("Error:") }) {
            lines[first...].prefix(conciseLineLimit)
        } else if let first = lines.firstIndex(where: { $0.hasPrefix("Warning:") }) {
            // brew can exit with a failure having printed only warnings (a post-install step
            // that didn't finish, say).
            lines[first...].prefix(conciseLineLimit)
        } else {
            lines.suffix(conciseLineLimit)
        }
        return relevant.joined(separator: "\n")
    }

    /// brew's notice that some tap's formula or cask uses a deprecated DSL — printed by every
    /// command that loads it, whatever the command was about:
    ///
    ///     Warning: Calling `postflight` is deprecated! Use `postflight_steps` instead.
    ///     Please report this issue to the user/homebrew-tap tap (not Homebrew/* repositories), …
    ///       /opt/homebrew/Library/Taps/user/homebrew-tap/Casks/name.rb:21
    ///
    /// Picked as the reason for a failure (the first "Warning:" when there's no "Error:"), it names
    /// the wrong package.
    private static func isTapDeprecationNotice(_ line: String) -> Bool {
        (line.hasPrefix("Warning: Calling ") && line.contains("deprecated"))
            || line.hasPrefix("Please report this issue to")
            // The notice's source line — not a real error that happens to name a tap's file.
            || (!line.hasPrefix("Error:") && line.contains("/Library/Taps/")
                && line.range(of: #"\.rb:\d+$"#, options: .regularExpression) != nil)
    }

    /// The formulae whose post-install step brew reports as failed. brew prints
    /// "You can try again using:" and then "  brew postinstall <name>" for each.
    static func failedPostinstallNames(in output: String) -> [String] {
        var names: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            guard words.count == 3, words[0] == "brew", words[1] == "postinstall" else { continue }
            if !names.contains(String(words[2])) { names.append(String(words[2])) }
        }
        return names
    }
}

// MARK: - LocalizedError

public extension BrewError {
    /// A plain-language next step for the failures people hit most. Matched on brew's own
    /// stderr wording; anything unmatched keeps its original message.
    static func friendlyHint(for stderr: String) -> String? {
        let text = stderr.lowercased()
        // First: this one isn't a failed install. The package is in place; only its last step isn't.
        if text.contains("post-install step did not complete successfully") {
            let names = failedPostinstallNames(in: stderr)
            guard !names.isEmpty else {
                return L("The package was installed, but its post-install step didn't finish.")
            }
            let list = names.joined(separator: " ")
            return L(
                "Installed, but the post-install step of \(list) didn't finish. To retry it, run: brew postinstall \(list)"
            )
        }
        // Homebrew's own `sudo` wrapper, answered by the askpass dialog (see `BrewService`).
        if text.contains("a password is required") || text.contains("no password was provided") {
            return L(
                "The administrator password wasn't entered, so Homebrew couldn't finish. Try again and enter your Mac's password when asked."
            )
        }
        // `sudo` needed approval and had no way to ask: Touch ID was cancelled (BrewMenu leaves the
        // password dialog out when `sudo` takes Touch ID, see `SudoTouchID`).
        if text.contains("a terminal is required to read the password") {
            return L(
                "The administrator approval was cancelled, so Homebrew couldn't finish. Try again and confirm with Touch ID when asked."
            )
        }
        if text.contains("incorrect password attempt") {
            return L("The administrator password was wrong. Try again with the password you use to log in to this Mac.")
        }
        // brew asks for this permission for "your terminal"; here, the app running brew is BrewMenu.
        if text.contains("app management") || (text.contains("operation not permitted") && text.contains(".app")) {
            return L(
                "macOS didn't let Homebrew change an app. Allow BrewMenu in System Settings › Privacy & Security › App Management, then try again."
            )
        }
        if text.contains("already an app at") {
            return L(
                "An app with the same name is already in Applications, but Homebrew didn't install it. Move it to the Trash, then try again."
            )
        }
        if text.contains("sha-256 mismatch") || text.contains("sha256 mismatch") {
            return L(
                "The download didn't match what Homebrew expected — usually a temporary problem with the server or a damaged cached file. Delete it in Cache, then try again."
            )
        }
        if text.contains("command line tools are too outdated") || text.contains("invalid active developer path") {
            return L(
                "Apple's Command Line Tools are missing or out of date. Update them in System Settings › General › Software Update, then try again."
            )
        }
        if text.contains("permission denied") {
            return L("Homebrew doesn't have permission to write here. Check who owns the Homebrew folder.")
        }
        if text.contains("already locked") || text.contains("another active homebrew process") {
            return L("Another Homebrew command is still running. Wait for it to finish, then try again.")
        }
        if text.contains("no space left on device") {
            return L("There isn't enough disk space. Free some space, then try again.")
        }
        if text.contains("could not resolve host") || text.contains("failed to connect") {
            return L("Couldn't reach the internet. Check your connection and try again.")
        }
        return nil
    }
}

extension BrewError: LocalizedError {
    /// Without this conformance, `error.localizedDescription` on a `BrewError` falls
    /// back to a generic bridged NSError description ("The operation couldn't be
    /// completed... error 1") — every real reason a brew command failed (the actual
    /// exit code and stderr) was silently swallowed everywhere the app just logged or
    /// displayed `error.localizedDescription` directly.
    public var errorDescription: String? {
        switch self {
        case .notFound:
            return L("Homebrew not found.")
        case .notConfigured:
            return L("Service not configured.")
        case let .commandFailed(code, stderr, _):
            let raw = L("Command failed (code \(code)): \(Self.conciseOutput(stderr))")
            // The raw text stays underneath the hint: logs and bug reports still need it.
            if let hint = Self.friendlyHint(for: stderr) { return "\(hint)\n\n\(raw)" }
            return raw
        case let .outputParsingFailed(cmd):
            return L("Could not parse output of '\(cmd)'.")
        case let .timedOut(cmd, seconds):
            return L("'\(cmd)' didn't finish within \(seconds) seconds, so it was stopped. Try again.")
        }
    }
}
