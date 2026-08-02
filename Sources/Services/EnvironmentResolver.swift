import Foundation

protocol FileSystemChecker: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
}

// Wrapper avoids retroactive Sendable conformance on Foundation's FileManager.
struct DefaultFileSystemChecker: FileSystemChecker {
    func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

actor EnvironmentResolver {
    static let defaultCandidates: [String] = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    private let fileSystem: any FileSystemChecker
    private var brewPath: String?
    private var shellEnvironment: [String: String]?
    private var configuredContinuations: [CheckedContinuation<Void, Never>] = []
    /// Set when `bootstrap()` fails (e.g. Homebrew not found at the configured
    /// path) — cleared by the next successful `configure()`. Without this,
    /// `waitUntilConfigured()` had no way to learn a bootstrap attempt had already
    /// failed and would suspend forever: `detectBrewPath` throwing before
    /// `configure()` is ever reached meant nothing was left to resume the waiters.
    private var bootstrapFailure: Error?

    init(fileSystem: any FileSystemChecker = DefaultFileSystemChecker()) {
        self.fileSystem = fileSystem
    }

    func detectBrewPath(customPath: String? = nil) throws -> String {
        let candidates = customPath.map { [$0] } ?? Self.defaultCandidates
        guard let found = candidates.first(where: { fileSystem.isExecutableFile(atPath: $0) }) else {
            throw BrewError.notFound(searchedPaths: candidates)
        }
        brewPath = found
        return found
    }

    func configure(brewPath: String, shellEnvironment: [String: String]) {
        self.brewPath = brewPath
        self.shellEnvironment = shellEnvironment
        bootstrapFailure = nil
        resumeWaiters()
    }

    /// Call from `BrewService.bootstrap()`'s failure path — lets anyone suspended
    /// in `waitUntilConfigured()` (or who calls it later, before a retry succeeds)
    /// fail fast with the real reason instead of hanging indefinitely.
    func markBootstrapFailed(_ error: Error) {
        bootstrapFailure = error
        resumeWaiters()
    }

    private func resumeWaiters() {
        let waiters = configuredContinuations
        configuredContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until `configure(...)` has run. Callers that can start before
    /// `BrewService.bootstrap()` finishes (e.g. the Dashboard window opening moments
    /// after launch) await real readiness here instead of polling `resolvedState()`
    /// in a blind retry loop. Throws the recorded bootstrap failure (past or, if one
    /// arrives while suspended, present) rather than waiting forever for a
    /// `configure()` call that a failed bootstrap will never make.
    func waitUntilConfigured() async throws {
        if isConfigured { return }
        if let bootstrapFailure { throw bootstrapFailure }
        await withCheckedContinuation { continuation in
            configuredContinuations.append(continuation)
        }
        if let bootstrapFailure { throw bootstrapFailure }
    }

    var resolvedBrewPath: String {
        get throws {
            guard let path = brewPath else { throw BrewError.notConfigured }
            return path
        }
    }

    var environment: [String: String] {
        get throws {
            guard let env = shellEnvironment else { throw BrewError.notConfigured }
            return env
        }
    }

    var isConfigured: Bool { brewPath != nil && shellEnvironment != nil }

    func resolvedState() throws -> (brewPath: String, environment: [String: String]) {
        guard let path = brewPath, let env = shellEnvironment else {
            throw BrewError.notConfigured
        }
        return (path, env)
    }
}
