import Testing
@testable import BrewMenu

struct MockFileSystem: FileSystemChecker {
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
            _ = try await resolver.detectBrewPath()
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

    @Test("waitUntilConfigured() retorna de inmediato si ya está configurado")
    func waitUntilConfiguredReturnsImmediatelyWhenAlreadyConfigured() async throws {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        await resolver.configure(brewPath: "/opt/homebrew/bin/brew", shellEnvironment: [:])
        try await resolver.waitUntilConfigured()
    }

    @Test("waitUntilConfigured() se resuelve cuando configure() llega después")
    func waitUntilConfiguredResumesOnConfigure() async throws {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        let waiter = Task { try await resolver.waitUntilConfigured() }
        try await Task.sleep(nanoseconds: 50_000_000)  // let the waiter start suspending
        await resolver.configure(brewPath: "/opt/homebrew/bin/brew", shellEnvironment: [:])
        try await waiter.value
    }

    // Regression: markBootstrapFailed() didn't exist — a bootstrap that failed before
    // ever calling configure() (e.g. brew not found) left waitUntilConfigured()
    // suspended forever, since nothing else was left to resume it. Confirmed against
    // both an already-recorded failure and one that arrives while suspended.
    @Test("waitUntilConfigured() tira el error registrado en vez de colgarse para siempre")
    func waitUntilConfiguredThrowsRecordedFailureInsteadOfHangingForever() async {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        await resolver.markBootstrapFailed(BrewError.notFound(searchedPaths: ["/opt/homebrew/bin/brew"]))
        await #expect(throws: BrewError.self) {
            try await resolver.waitUntilConfigured()
        }
    }

    @Test("waitUntilConfigured() tira si una falla de bootstrap llega mientras está suspendido")
    func waitUntilConfiguredThrowsWhenFailureArrivesWhileSuspended() async {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        let waiter = Task { try await resolver.waitUntilConfigured() }
        try? await Task.sleep(nanoseconds: 50_000_000)  // let the waiter start suspending
        await resolver.markBootstrapFailed(BrewError.notFound(searchedPaths: ["/opt/homebrew/bin/brew"]))

        await #expect(throws: BrewError.self) {
            try await waiter.value
        }
    }

    @Test("una falla anterior no bloquea un configure() posterior exitoso (reintento)")
    func laterConfigureClearsEarlierFailure() async throws {
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: []))
        await resolver.markBootstrapFailed(BrewError.notFound(searchedPaths: ["/opt/homebrew/bin/brew"]))
        await resolver.configure(brewPath: "/opt/homebrew/bin/brew", shellEnvironment: [:])

        try await resolver.waitUntilConfigured()
    }
}
