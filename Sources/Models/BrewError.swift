import Foundation

enum BrewError: Error, Equatable {
    case notFound(searchedPaths: [String])
    case notConfigured
    case commandFailed(exitCode: Int32, stderr: String)
    case outputParsingFailed(command: String)
}

// MARK: - LocalizedError

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
            return L("Command failed (code \(code)): \(stderr)")
        case .outputParsingFailed(let cmd):
            return L("Could not parse output of '\(cmd)'.")
        }
    }
}
