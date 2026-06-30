import Testing
@testable import BrewMenu

// MARK: - Mock

final class MockProcessRunner: ProcessRunner, @unchecked Sendable {
    struct Call {
        let executablePath: String
        let arguments: [String]
    }

    var responses: [ProcessResult] = []
    private(set) var calls: [Call] = []

    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult {
        calls.append(Call(executablePath: executablePath, arguments: arguments))
        guard !responses.isEmpty else {
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        return responses.removeFirst()
    }

    func runStreaming(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        calls.append(Call(executablePath: executablePath, arguments: arguments))
        guard !responses.isEmpty else {
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        return responses.removeFirst()
    }
}

private extension ProcessResult {
    static func success(stdout: String = "") -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
    static func failure(exitCode: Int32 = 1, stderr: String = "error") -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: "", stderr: stderr)
    }
}

// MARK: - Fixtures

private let shellenvOutput = """
export HOMEBREW_PREFIX="/opt/homebrew";
export HOMEBREW_CELLAR="/opt/homebrew/Cellar";
export HOMEBREW_REPOSITORY="/opt/homebrew";
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin";
export MANPATH="/opt/homebrew/share/man::";
export INFOPATH="/opt/homebrew/share/info:";
"""

private let outdatedJSON = """
{
  "formulae": [
    {
      "name": "git",
      "installed_versions": ["2.39.0"],
      "current_version": "2.40.0",
      "pinned": false
    }
  ],
  "casks": [
    {
      "name": "iterm2",
      "installed_versions": ["3.4.0"],
      "current_version": "3.5.0",
      "pinned": false
    }
  ]
}
"""

// MARK: - Helpers

private func makeService(
    runner: MockProcessRunner,
    executablePaths: Set<String> = ["/opt/homebrew/bin/brew"]
) -> (BrewService, EnvironmentResolver) {
    let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: executablePaths))
    let service = BrewService(resolver: resolver, runner: runner)
    return (service, resolver)
}

private struct MockFileSystem: FileSystemChecker {
    var executablePaths: Set<String>
    func isExecutableFile(atPath path: String) -> Bool { executablePaths.contains(path) }
}

private let servicesJSON = """
[
  {"name": "nginx",      "status": "started", "user": "root",  "file": "/tmp/nginx.plist",  "exit_code": null},
  {"name": "postgresql", "status": "stopped", "user": null,    "file": "/tmp/pg.plist",     "exit_code": 1},
  {"name": "redis",      "status": "none",    "user": null,    "file": "/tmp/redis.plist",  "exit_code": null}
]
"""

// MARK: - Tests

@Suite("BrewService")
struct BrewServiceTests {

    // MARK: bootstrap

    @Test("bootstrap detecta path y configura resolver con shellenv")
    func bootstrapConfiguresResolver() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput)]
        let (service, resolver) = makeService(runner: runner)

        try await service.bootstrap()

        let configured = await resolver.isConfigured
        #expect(configured)

        let env = try await resolver.environment
        #expect(env["HOMEBREW_PREFIX"] == "/opt/homebrew")
        #expect(env["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin")
    }

    @Test("bootstrap ejecuta brew shellenv con path correcto")
    func bootstrapCallsShellenv() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput)]
        let (service, _) = makeService(runner: runner)

        try await service.bootstrap()

        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].arguments == ["shellenv", "--shell=bash"])
        #expect(runner.calls[0].executablePath == "/opt/homebrew/bin/brew")
    }

    @Test("bootstrap con path custom lo pasa a EnvironmentResolver")
    func bootstrapUsesCustomPath() async throws {
        let custom = "/custom/bin/brew"
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput)]
        let (service, _) = makeService(runner: runner, executablePaths: [custom])

        try await service.bootstrap(customBrewPath: custom)

        #expect(runner.calls[0].executablePath == custom)
    }

    @Test("bootstrap tira notFound cuando brew no existe")
    func bootstrapThrowsWhenBrewMissing() async {
        let runner = MockProcessRunner()
        let (service, _) = makeService(runner: runner, executablePaths: [])

        await #expect(throws: BrewError.self) {
            try await service.bootstrap()
        }
        #expect(runner.calls.isEmpty) // no llegó a correr shellenv
    }

    @Test("bootstrap tira commandFailed cuando shellenv falla")
    func bootstrapThrowsOnShellenvFailure() async {
        let runner = MockProcessRunner()
        runner.responses = [.failure(exitCode: 1, stderr: "brew error")]
        let (service, _) = makeService(runner: runner)

        await #expect(throws: BrewError.self) {
            try await service.bootstrap()
        }
    }

    // MARK: fetchOutdated

    @Test("fetchOutdated devuelve formulae y casks combinados")
    func fetchOutdatedReturnsBoth() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: outdatedJSON),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let packages = try await service.fetchOutdated()

        #expect(packages.count == 2)
        #expect(packages[0].name == "git")
        #expect(packages[0].currentVersion == "2.40.0")
        #expect(packages[0].installedVersions == ["2.39.0"])
        #expect(packages[1].name == "iterm2")
    }

    @Test("fetchOutdated devuelve lista vacía cuando no hay outdated")
    func fetchOutdatedReturnsEmpty() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: #"{"formulae":[],"casks":[]}"#),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let packages = try await service.fetchOutdated()
        #expect(packages.isEmpty)
    }

    @Test("fetchOutdated tira outputParsingFailed con JSON inválido")
    func fetchOutdatedThrowsOnBadJSON() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: "not json"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.self) {
            try await service.fetchOutdated()
        }
    }

    @Test("fetchOutdated tira notConfigured antes de bootstrap")
    func fetchOutdatedThrowsBeforeBootstrap() async {
        let runner = MockProcessRunner()
        let (service, _) = makeService(runner: runner)

        await #expect(throws: BrewError.self) {
            try await service.fetchOutdated()
        }
    }

    // MARK: runUpdate

    @Test("runUpdate ejecuta brew update")
    func runUpdateCallsBrew() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.runUpdate()

        #expect(runner.calls[1].arguments == ["update"])
    }

    @Test("runUpdate tira commandFailed cuando brew update falla")
    func runUpdateThrowsOnFailure() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "update failed"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.self) {
            try await service.runUpdate()
        }
    }

    // MARK: runUpgradeAll

    @Test("runUpgradeAll ejecuta brew upgrade")
    func runUpgradeAllCallsBrew() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.runUpgradeAll(onLine: { _ in })

        #expect(runner.calls[1].arguments == ["upgrade"])
    }

    // MARK: fetchServices

    @Test("fetchServices parsea started, stopped y none correctamente")
    func fetchServicesParsesMixed() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: servicesJSON),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let entries = try await service.fetchServices()

        #expect(entries.count == 3)
        #expect(entries[0].name == "nginx")
        #expect(entries[0].status == .started)
        #expect(entries[0].user == "root")
        #expect(entries[1].name == "postgresql")
        #expect(entries[1].status == .stopped)
        #expect(entries[1].exitCode == 1)
        #expect(entries[2].name == "redis")
        #expect(entries[2].status == .inactive)
    }

    @Test("fetchServices con lista vacía devuelve array vacío")
    func fetchServicesEmpty() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: "[]"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let entries = try await service.fetchServices()
        #expect(entries.isEmpty)
    }

    @Test("startService ejecuta brew services start <name>")
    func startServiceCallsBrew() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput), .success()]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.startService("nginx")

        #expect(runner.calls[1].arguments == ["services", "start", "nginx"])
    }

    @Test("stopService ejecuta brew services stop <name>")
    func stopServiceCallsBrew() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput), .success()]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.stopService("postgresql")

        #expect(runner.calls[1].arguments == ["services", "stop", "postgresql"])
    }

    // MARK: runCleanupDryRun

    @Test("runCleanupDryRun ejecuta brew cleanup --dry-run")
    func runCleanupDryRunCallsBrew() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: "==> This operation would free approximately 1.2 GB of disk space."),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let bytes = try await service.runCleanupDryRun()

        #expect(runner.calls[1].arguments == ["cleanup", "--dry-run"])
        #expect(bytes > 0)
    }

    @Test("parseCleanupBytes parsea GB correctamente")
    func parseCleanupBytesGB() {
        let output = "==> This operation would free approximately 1.5 GB of disk space."
        let bytes = BrewService.parseCleanupBytes(output)
        #expect(bytes == Int64(1.5 * 1_073_741_824))
    }

    @Test("parseCleanupBytes parsea MB correctamente")
    func parseCleanupBytesMB() {
        let output = "==> This operation would free approximately 500 MB of disk space."
        let bytes = BrewService.parseCleanupBytes(output)
        #expect(bytes == 500 * 1_048_576)
    }

    @Test("parseCleanupBytes devuelve 0 cuando no hay nada que limpiar")
    func parseCleanupBytesEmpty() {
        let bytes = BrewService.parseCleanupBytes("")
        #expect(bytes == 0)
    }

    @Test("parseCleanupBytes devuelve 0 con output sin patrón reconocible")
    func parseCleanupBytesUnknownFormat() {
        let bytes = BrewService.parseCleanupBytes("Nothing to do.")
        #expect(bytes == 0)
    }

    // MARK: parseInstalledCasks

    @Test("parseInstalledCasks parsea líneas válidas name version")
    func parseInstalledCasksBasic() {
        let output = "alfred 5.5.2\niterm2 3.5.0\nbrave-browser 1.64.116"
        let casks = BrewService.parseInstalledCasks(output)
        #expect(casks.count == 3)
        #expect(casks[0].name == "alfred")
        #expect(casks[0].version == "5.5.2")
        #expect(casks[1].name == "iterm2")
        #expect(casks[2].name == "brave-browser")
    }

    @Test("parseInstalledCasks ignora líneas vacías y malformadas")
    func parseInstalledCasksIgnoresBadLines() {
        let output = "\nalfred 5.5.2\n\nsolonombre\n"
        let casks = BrewService.parseInstalledCasks(output)
        #expect(casks.count == 1)
        #expect(casks[0].name == "alfred")
    }

    @Test("parseInstalledCasks con output vacío devuelve array vacío")
    func parseInstalledCasksEmpty() {
        let casks = BrewService.parseInstalledCasks("")
        #expect(casks.isEmpty)
    }

    // MARK: parseShellenv (via bootstrap integration)

    @Test("parseShellenv extrae las seis variables estándar de Homebrew")
    func parseShellenvExtractsAllKeys() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput)]
        let (service, resolver) = makeService(runner: runner)
        try await service.bootstrap()

        let env = try await resolver.environment
        let expectedKeys = ["HOMEBREW_PREFIX", "HOMEBREW_CELLAR", "HOMEBREW_REPOSITORY", "PATH", "MANPATH", "INFOPATH"]
        for key in expectedKeys {
            #expect(env[key] != nil, "Falta la clave \(key)")
        }
    }
}
