import Testing
import Foundation
@testable import BrewMenu

// MARK: - Mock

final class MockProcessRunner: ProcessRunner, @unchecked Sendable {
    struct Call {
        let executablePath: String
        let arguments: [String]
    }

    var responses: [ProcessResult] = []
    /// Optional argument-keyed responder, checked before the FIFO `responses` queue —
    /// needed for callers (like `searchPackages`) that now launch two `runner.run` calls
    /// concurrently via `async let`, where arrival order into `calls`/`responses` isn't
    /// guaranteed. Existing sequential-call tests are unaffected: this is nil by default,
    /// so they keep using positional `responses`.
    var responseForArguments: (@Sendable ([String]) -> ProcessResult?)?
    private(set) var calls: [Call] = []
    private let lock = NSLock()

    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult {
        lock.withLock {
            calls.append(Call(executablePath: executablePath, arguments: arguments))
            if let handler = responseForArguments, let response = handler(arguments) {
                return response
            }
            guard !responses.isEmpty else {
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
            return responses.removeFirst()
        }
    }

    func runStreaming(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        lock.withLock {
            calls.append(Call(executablePath: executablePath, arguments: arguments))
            guard !responses.isEmpty else {
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
            return responses.removeFirst()
        }
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

private let infoInstalledJSON = """
{
  "formulae": [
    {
      "name": "git",
      "tap": "homebrew/core",
      "desc": "Distributed revision control system",
      "homepage": "https://git-scm.com",
      "installed": [{"version": "2.43.0"}],
      "pinned": false,
      "outdated": false,
      "deprecated": false,
      "disabled": false
    },
    {
      "name": "my-tool",
      "tap": "dotfn/tap",
      "desc": "A custom tool",
      "homepage": "https://example.com",
      "installed": [{"version": "1.0.0"}],
      "pinned": true,
      "outdated": true,
      "deprecated": false,
      "disabled": false
    },
    {
      "name": "old-formula",
      "tap": "homebrew/core",
      "desc": "A formula on its way out",
      "homepage": "https://example.com",
      "installed": [{"version": "0.9.0"}],
      "pinned": false,
      "outdated": false,
      "deprecated": true,
      "deprecation_reason": "unmaintained",
      "disabled": false
    }
  ],
  "casks": [
    {
      "token": "iterm2",
      "tap": "homebrew/cask",
      "desc": "Terminal emulator",
      "homepage": "https://iterm2.com",
      "version": "3.5.0",
      "pinned": false,
      "outdated": false,
      "deprecated": false,
      "disabled": false
    },
    {
      "token": "orca",
      "tap": "homebrew/cask",
      "desc": "Generate images of interactive plotly charts",
      "homepage": "https://github.com/plotly/orca/",
      "version": "1.3.1",
      "pinned": false,
      "outdated": false,
      "deprecated": true,
      "deprecation_reason": "fails_gatekeeper_check",
      "disabled": true,
      "disable_date": "2026-09-01",
      "disable_reason": "fails_gatekeeper_check"
    }
  ]
}
"""

private let infoResolveCaskJSON = """
{
  "formulae": [],
  "casks": [
    {
      "token": "orca",
      "tap": "stablyai/orca",
      "desc": "Screen reader",
      "homepage": "https://example.com",
      "version": "1.0.0",
      "pinned": false,
      "outdated": false,
      "deprecated": false,
      "disabled": false
    }
  ]
}
"""

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

    // MARK: runAutoremoveDryRun / runAutoremove / parseAutoremoveNames

    @Test("runAutoremoveDryRun ejecuta brew autoremove --dry-run y parsea los nombres")
    func runAutoremoveDryRunCallsBrew() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: "==> Would autoremove 2 unneeded formulae:\nfoo\nbar\n"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let names = try await service.runAutoremoveDryRun()

        #expect(runner.calls[1].arguments == ["autoremove", "--dry-run"])
        #expect(names == ["foo", "bar"])
    }

    @Test("runAutoremoveDryRun sin output (nada para sacar) devuelve vacío")
    func runAutoremoveDryRunNothingToRemove() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: ""),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let names = try await service.runAutoremoveDryRun()
        #expect(names.isEmpty)
    }

    @Test("runAutoremove ejecuta brew autoremove (sin --dry-run)")
    func runAutoremoveCallsBrew() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: "==> Autoremoving 1 unneeded formula:\nfoo\n"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.runAutoremove { _ in }

        #expect(runner.calls[1].arguments == ["autoremove"])
    }

    @Test("runAutoremove tira commandFailed cuando brew autoremove falla")
    func runAutoremoveFailureThrows() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "boom"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.commandFailed(exitCode: 1, stderr: "boom")) {
            try await service.runAutoremove { _ in }
        }
    }

    @Test("parseAutoremoveNames ignora la línea de encabezado ==> y líneas vacías")
    func parseAutoremoveNamesSkipsHeaderAndBlankLines() {
        let names = BrewService.parseAutoremoveNames("==> Would autoremove 2 unneeded formulae:\nfoo\n\nbar\n")
        #expect(names == ["foo", "bar"])
    }

    @Test("parseAutoremoveNames con output vacío devuelve vacío")
    func parseAutoremoveNamesEmptyOutput() {
        #expect(BrewService.parseAutoremoveNames("").isEmpty)
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

    // MARK: fetchInstalledPackages

    @Test("fetchInstalledPackages parsea formulae y casks con tap, pinned, outdated")
    func fetchInstalledPackagesParsesBoth() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: infoInstalledJSON),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let packages = try await service.fetchInstalledPackages()

        #expect(packages.count == 5)
        let git = try #require(packages.first { $0.name == "git" })
        #expect(git.tap == "homebrew/core")
        #expect(git.isCask == false)
        #expect(git.version == "2.43.0")
        #expect(!git.deprecated)
        #expect(!git.disabled)

        let tool = try #require(packages.first { $0.name == "my-tool" })
        #expect(tool.tap == "dotfn/tap")
        #expect(tool.pinned)
        #expect(tool.outdated)

        let cask = try #require(packages.first { $0.name == "iterm2" })
        #expect(cask.isCask)
        #expect(cask.tap == "homebrew/cask")
        #expect(cask.version == "3.5.0")

        let oldFormula = try #require(packages.first { $0.name == "old-formula" })
        #expect(oldFormula.deprecated)
        #expect(oldFormula.deprecationReason == "unmaintained")
        #expect(!oldFormula.disabled)

        let orca = try #require(packages.first { $0.name == "orca" })
        #expect(orca.isCask)
        #expect(orca.deprecated)
        #expect(orca.disabled)
        #expect(orca.disableReason == "fails_gatekeeper_check")

        #expect(runner.calls[1].arguments == ["info", "--json=v2", "--installed"])
    }

    @Test("fetchInstalledPackages tira outputParsingFailed con JSON inválido")
    func fetchInstalledPackagesThrowsOnBadJSON() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: "not json"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.self) {
            try await service.fetchInstalledPackages()
        }
    }

    // MARK: resolvePackage

    @Test("resolvePackage encuentra un formula y expone name/tap/desc")
    func resolvePackageFindsFormula() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput), .success(stdout: infoInstalledJSON)]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let resolved = try await service.resolvePackage("git")

        #expect(resolved?.name == "git")
        #expect(resolved?.tap == "homebrew/core")
        #expect(resolved?.isCask == false)
        #expect(runner.calls[1].arguments == ["info", "--json=v2", "git"])
    }

    @Test("resolvePackage encuentra un cask de un tap de terceros por su nombre completo")
    func resolvePackageFindsThirdPartyCask() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput), .success(stdout: infoResolveCaskJSON)]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let resolved = try await service.resolvePackage("stablyai/orca/orca")

        #expect(resolved?.name == "orca")
        #expect(resolved?.tap == "stablyai/orca")
        #expect(resolved?.isCask == true)
        #expect(runner.calls[1].arguments == ["info", "--json=v2", "stablyai/orca/orca"])
    }

    @Test("resolvePackage propaga el stderr real de brew info cuando falla, en vez de devolver nil")
    func resolvePackageThrowsRealErrorWhenBrewInfoFails() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "Error: No available formula or cask with the name \"doesnotexist\"."),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.commandFailed(exitCode: 1, stderr: "Error: No available formula or cask with the name \"doesnotexist\".")) {
            try await service.resolvePackage("doesnotexist")
        }
    }

    @Test("resolvePackage tapea y reintenta cuando brew info exige un tap no agregado, para un nombre user/repo/name")
    func resolvePackageAutoTapsAndRetriesForQualifiedName() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "Error: No available formula or cask with the name \"stablyai/orca/orca\".\nThis command requires the tap stablyai/orca."),
            .success(), // brew tap stablyai/orca
            .success(stdout: infoResolveCaskJSON), // retry
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let resolved = try await service.resolvePackage("stablyai/orca/orca")

        #expect(resolved?.name == "orca")
        #expect(resolved?.tap == "stablyai/orca")
        #expect(resolved?.didAutoTap == true)
        #expect(runner.calls[1].arguments == ["info", "--json=v2", "stablyai/orca/orca"])
        #expect(runner.calls[2].arguments == ["tap", "stablyai/orca"])
        #expect(runner.calls[3].arguments == ["info", "--json=v2", "stablyai/orca/orca"])
    }

    @Test("resolvePackage no reintenta tap para un nombre de un solo segmento")
    func resolvePackageDoesNotAutoTapForBareName() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "Error: No available formula or cask with the name \"ghost\"."),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.self) {
            try await service.resolvePackage("ghost")
        }
        #expect(runner.calls.count == 2) // shellenv + info, sin intento de tap
    }

    @Test("resolvePackage propaga el error original de info si el tap de respaldo también falla")
    func resolvePackageSurfacesOriginalErrorWhenTapAlsoFails() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "This command requires the tap ghost/repo."),
            .failure(exitCode: 1, stderr: "Error: Invalid tap name"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.commandFailed(exitCode: 1, stderr: "This command requires the tap ghost/repo.")) {
            try await service.resolvePackage("ghost/repo/name")
        }
    }

    // MARK: fetchTaps / parseTaps

    @Test("fetchTaps ejecuta brew tap y parsea una línea por tap")
    func fetchTapsCallsBrew() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: "homebrew/core\nhomebrew/cask\ndotfn/tap\n"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let taps = try await service.fetchTaps()

        #expect(taps.map(\.name) == ["homebrew/core", "homebrew/cask", "dotfn/tap"])
        #expect(runner.calls[1].arguments == ["tap"])
    }

    @Test("parseTaps ignora líneas vacías")
    func parseTapsIgnoresBlankLines() {
        let taps = BrewService.parseTaps("\nhomebrew/core\n\n")
        #expect(taps.count == 1)
        #expect(taps[0].name == "homebrew/core")
    }

    // MARK: fetchTapPackages

    @Test("fetchTapPackages parsea formula_names y cask_tokens de brew tap-info, ordenado por nombre")
    func fetchTapPackagesParsesTapInfo() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: """
            [{"name":"dotfn/tap","formula_names":["portkiller","lumus-control"],"cask_tokens":["some-app"]}]
            """),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let packages = try await service.fetchTapPackages("dotfn/tap")

        #expect(packages.map(\.name) == ["lumus-control", "portkiller", "some-app"])
        #expect(packages.first { $0.name == "some-app" }?.isCask == true)
        #expect(packages.first { $0.name == "portkiller" }?.isCask == false)
        #expect(runner.calls[1].arguments == ["tap-info", "--json=v1", "dotfn/tap"])
    }

    @Test("fetchTapPackages quita el prefijo del tap de cask_tokens tap-qualified")
    func fetchTapPackagesStripsTapPrefixFromCaskTokens() async throws {
        // Confirmed empirically against a real third-party tap (stablyai/orca):
        // `brew tap-info --json=v1` returns cask_tokens as "user/repo/token", not the
        // bare token every other package name in the app uses.
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: """
            [{"name":"stablyai/orca","formula_names":[],"cask_tokens":["stablyai/orca/orca","stablyai/orca/orca@rc"]}]
            """),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let packages = try await service.fetchTapPackages("stablyai/orca")

        #expect(packages.map(\.name) == ["orca", "orca@rc"])
        #expect(try packages.allSatisfy(\.isCask))
    }

    @Test("fetchTapPackages ante tap sin formulae ni casks devuelve vacío")
    func fetchTapPackagesEmptyTap() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: """
            [{"name":"dotfn/tap","formula_names":[],"cask_tokens":[]}]
            """),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let packages = try await service.fetchTapPackages("dotfn/tap")
        #expect(packages.isEmpty)
    }

    @Test("fetchTapPackages ante output inválido tira outputParsingFailed")
    func fetchTapPackagesInvalidOutput() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .success(stdout: "not json"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.outputParsingFailed(command: "tap-info --json=v1 dotfn/tap")) {
            try await service.fetchTapPackages("dotfn/tap")
        }
    }

    // MARK: searchPackages / parseSearchLines

    @Test("searchPackages combina resultados de --formula y --cask")
    func searchPackagesCombinesFormulaAndCask() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput)]
        // searchPackages runs its --formula and --cask spawns concurrently, so their
        // arrival order into a FIFO responses queue isn't guaranteed — match by argument
        // content instead.
        runner.responseForArguments = { arguments in
            if arguments.contains("--formula") { return .success(stdout: "node\nnode@18\nnode-build\n") }
            if arguments.contains("--cask") { return .success(stdout: "font-node\n") }
            return nil
        }
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let results = try await service.searchPackages("node")

        #expect(results.count == 4)
        #expect(results.filter { !$0.isCask }.map(\.name) == ["node", "node@18", "node-build"])
        #expect(results.filter(\.isCask).map(\.name) == ["font-node"])
        #expect(runner.calls.contains { $0.arguments == ["search", "--formula", "node"] })
        #expect(runner.calls.contains { $0.arguments == ["search", "--cask", "node"] })
    }

    @Test("searchPackages sin resultados (exit 1) devuelve array vacío, no tira")
    func searchPackagesNoMatchesReturnsEmpty() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "Error: No formulae or casks found for \"zzz\"."),
            .failure(exitCode: 1, stderr: "Error: No formulae or casks found for \"zzz\"."),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        let results = try await service.searchPackages("zzz")
        #expect(results.isEmpty)
    }

    @Test("parseSearchLines ignora líneas vacías")
    func parseSearchLinesIgnoresBlankLines() {
        let lines = BrewService.parseSearchLines("\nnode\n\nnode@18\n")
        #expect(lines == ["node", "node@18"])
    }

    @Test("rankedByRelevance pone el match exacto primero, sin importar el orden original")
    func rankedByRelevancePrioritizesExactMatch() {
        let results = [
            SearchResult(name: "claude-cmd", isCask: false),
            SearchResult(name: "claude-code-templates", isCask: false),
            SearchResult(name: "auto-claude", isCask: true),
            SearchResult(name: "claude", isCask: true),   // exact match, was buried mid-list
            SearchResult(name: "claude-code", isCask: true),
        ]

        let ranked = BrewService.rankedByRelevance(results, query: "claude")

        #expect(ranked.first?.name == "claude")
    }

    @Test("rankedByRelevance ordena por tier: exacto, prefijo, contiene")
    func rankedByRelevanceOrdersByTier() {
        let results = [
            SearchResult(name: "font-node", isCask: true),   // contains
            SearchResult(name: "node-build", isCask: false),  // prefix
            SearchResult(name: "node", isCask: false),        // exact
            SearchResult(name: "node@18", isCask: false),     // prefix, shorter than node-build
        ]

        let ranked = BrewService.rankedByRelevance(results, query: "node")

        #expect(ranked.map(\.name) == ["node", "node@18", "node-build", "font-node"])
    }

    // MARK: installPackage

    @Test("installPackage ejecuta brew install <name> para formulae")
    func installPackageCallsBrewForFormula() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput), .success()]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.installPackage("wget", isCask: false, onLine: { _ in })

        #expect(runner.calls[1].arguments == ["install", "wget"])
    }

    @Test("installPackage ejecuta brew install --cask <name> para casks")
    func installPackageCallsBrewForCask() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput), .success()]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.installPackage("iterm2", isCask: true, onLine: { _ in })

        #expect(runner.calls[1].arguments == ["install", "--cask", "iterm2"])
    }

    @Test("installPackage tira commandFailed cuando brew install falla")
    func installPackageThrowsOnFailure() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "install failed"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.self) {
            try await service.installPackage("wget", isCask: false, onLine: { _ in })
        }
    }

    // MARK: addTap

    @Test("addTap ejecuta brew tap <name>")
    func addTapCallsBrew() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput), .success()]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.addTap("someuser/sometap", onLine: { _ in })

        #expect(runner.calls[1].arguments == ["tap", "someuser/sometap"])
    }

    @Test("addTap tira commandFailed cuando brew tap falla")
    func addTapThrowsOnFailure() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "repository not found"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.self) {
            try await service.addTap("ghost/doesnotexist", onLine: { _ in })
        }
    }

    // MARK: removeTap

    @Test("removeTap ejecuta brew untap <name>")
    func removeTapCallsBrew() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput), .success()]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.removeTap("stablyai/orca")

        #expect(runner.calls[1].arguments == ["untap", "stablyai/orca"])
    }

    @Test("removeTap tira commandFailed cuando brew untap falla")
    func removeTapThrowsOnFailure() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "no such tap"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.self) {
            try await service.removeTap("stablyai/orca")
        }
    }

    // MARK: uninstallPackage

    @Test("uninstallPackage ejecuta brew uninstall <name> para formulae")
    func uninstallPackageCallsBrewForFormula() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput), .success()]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.uninstallPackage("wget", isCask: false, onLine: { _ in })

        #expect(runner.calls[1].arguments == ["uninstall", "wget"])
    }

    @Test("uninstallPackage ejecuta brew uninstall --cask <name> para casks")
    func uninstallPackageCallsBrewForCask() async throws {
        let runner = MockProcessRunner()
        runner.responses = [.success(stdout: shellenvOutput), .success()]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        try await service.uninstallPackage("iterm2", isCask: true, onLine: { _ in })

        #expect(runner.calls[1].arguments == ["uninstall", "--cask", "iterm2"])
    }

    @Test("uninstallPackage tira commandFailed cuando brew uninstall falla")
    func uninstallPackageThrowsOnFailure() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            .success(stdout: shellenvOutput),
            .failure(exitCode: 1, stderr: "uninstall failed"),
        ]
        let (service, _) = makeService(runner: runner)
        try await service.bootstrap()

        await #expect(throws: BrewError.self) {
            try await service.uninstallPackage("wget", isCask: false, onLine: { _ in })
        }
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
