import Testing
@testable import BrewMenu

private struct MockFileSystem: FileSystemChecker {
    var executablePaths: Set<String>
    func isExecutableFile(atPath path: String) -> Bool { executablePaths.contains(path) }
}

@Suite("EnvironmentResolver")
struct EnvironmentResolverTests {

    @Test("Detecta path Apple Silicon cuando existe")
    func detectsAppleSiliconPath() async throws {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: ["/opt/homebrew/bin/brew"]))
        let path = try await resolver.detectBrewPath()
        #expect(path == "/opt/homebrew/bin/brew")
    }

    @Test("Cae a Intel cuando Apple Silicon no existe")
    func fallsBackToIntelPath() async throws {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: ["/usr/local/bin/brew"]))
        let path = try await resolver.detectBrewPath()
        #expect(path == "/usr/local/bin/brew")
    }

    @Test("Prefiere Apple Silicon sobre Intel cuando ambos existen")
    func prefersSiliconOverIntel() async throws {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
        ]))
        let path = try await resolver.detectBrewPath()
        #expect(path == "/opt/homebrew/bin/brew")
    }

    @Test("Usa path custom cuando se provee")
    func usesCustomPath() async throws {
        let custom = "/custom/bin/brew"
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: [custom]))
        let path = try await resolver.detectBrewPath(customPath: custom)
        #expect(path == custom)
    }

    @Test("Tira notFound cuando ningún path existe")
    func throwsNotFoundWhenMissing() async {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        await #expect(throws: BrewError.self) {
            try await resolver.detectBrewPath()
        }
    }

    @Test("notFound incluye los paths buscados")
    func notFoundIncludesSearchedPaths() async {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        do {
            try await resolver.detectBrewPath()
            Issue.record("Se esperaba error")
        } catch let error as BrewError {
            guard case .notFound(let paths) = error else {
                Issue.record("Error incorrecto: \(error)")
                return
            }
            #expect(paths == EnvironmentResolver.defaultCandidates)
        } catch {
            Issue.record("Error inesperado: \(error)")
        }
    }

    @Test("configure() almacena el entorno y environment lo devuelve")
    func storesEnvironment() async throws {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        let env = ["HOMEBREW_PREFIX": "/opt/homebrew", "PATH": "/opt/homebrew/bin:/usr/bin"]
        await resolver.configure(brewPath: "/opt/homebrew/bin/brew", shellEnvironment: env)
        let retrieved = try await resolver.environment
        #expect(retrieved == env)
    }

    @Test("isConfigured es false antes de configure()")
    func notConfiguredBeforeSetup() async {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        let configured = await resolver.isConfigured
        #expect(!configured)
    }

    @Test("isConfigured es true después de configure()")
    func configuredAfterSetup() async {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        await resolver.configure(brewPath: "/opt/homebrew/bin/brew", shellEnvironment: [:])
        let configured = await resolver.isConfigured
        #expect(configured)
    }

    @Test("environment tira notConfigured antes de configure()")
    func throwsNotConfiguredForEnvironment() async {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        await #expect(throws: BrewError.self) {
            try await resolver.environment
        }
    }

    @Test("resolvedBrewPath tira notConfigured antes de detectar")
    func throwsNotConfiguredForBrewPath() async {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        await #expect(throws: BrewError.self) {
            try await resolver.resolvedBrewPath
        }
    }
}
