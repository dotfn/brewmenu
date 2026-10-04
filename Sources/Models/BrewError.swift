import Foundation

enum BrewError: Error, Equatable {
    case notFound(searchedPaths: [String])
    case notConfigured
    /// `command` is the brew invocation that failed, e.g. "brew upgrade wget". It's diagnostic
    /// context only: `errorDescription` and equality on the message don't depend on it.
    case commandFailed(exitCode: Int32, stderr: String, command: String = "")
    case outputParsingFailed(command: String)
}

extension BrewError {
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
            return "\(head)\nexit code \(code)\n\(stderr)"
        default:
            return localizedDescription
        }
    }
}

// MARK: - LocalizedError

extension BrewError {
    /// A plain-language next step for the failures people hit most. Matched on brew's own
    /// stderr wording; anything unmatched keeps its original message.
    static func friendlyHint(for stderr: String) -> String? {
        let text = stderr.lowercased()
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
    var errorDescription: String? {
        switch self {
        case .notFound:
            return L("Homebrew not found.")
        case .notConfigured:
            return L("Service not configured.")
        case let .commandFailed(code, stderr, _):
            let raw = L("Command failed (code \(code)): \(stderr)")
            // The raw text stays underneath the hint: logs and bug reports still need it.
            if let hint = Self.friendlyHint(for: stderr) { return "\(hint)\n\n\(raw)" }
            return raw
        case let .outputParsingFailed(cmd):
            return L("Could not parse output of '\(cmd)'.")
        }
    }
}
