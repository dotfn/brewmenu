import Foundation

enum BrewError: Error, Equatable {
    case notFound(searchedPaths: [String])
    case notConfigured
    case commandFailed(exitCode: Int32, stderr: String)
    case outputParsingFailed(command: String)
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
        case .commandFailed(let code, let stderr):
            let raw = L("Command failed (code \(code)): \(stderr)")
            // The raw text stays underneath the hint: logs and bug reports still need it.
            if let hint = Self.friendlyHint(for: stderr) { return "\(hint)\n\n\(raw)" }
            return raw
        case .outputParsingFailed(let cmd):
            return L("Could not parse output of '\(cmd)'.")
        }
    }
}
