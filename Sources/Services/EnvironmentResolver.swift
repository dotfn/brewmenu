import Foundation

protocol FileSystemChecker: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
}

extension FileManager: FileSystemChecker {}

actor EnvironmentResolver {
    static let defaultCandidates: [String] = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    private let fileSystem: any FileSystemChecker
    private var brewPath: String?
    private var shellEnvironment: [String: String]?

    init(fileSystem: any FileSystemChecker = FileManager.default) {
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
