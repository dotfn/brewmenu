import BrewCore
@testable import BrewMenu
import Foundation
import Testing

@Suite("BrewError — mensaje legible")
struct BrewErrorConciseOutputTests {
    @Test("se queda con el Error: de brew y descarta el medidor de curl")
    func keepsBrewErrorAndDropsProgressMeter() {
        let stderr = "==> Downloading https://example.com/a.dmg\n##   12.5%\r####   48.0%\r######## 100.0%\n"
            + "Error: It seems there is already an App at '/Applications/Orca.app'.\n"

        #expect(BrewError
            .conciseOutput(stderr) == "Error: It seems there is already an App at '/Applications/Orca.app'.")
    }

    @Test("sin línea Error: deja las últimas líneas, no todo el volcado")
    func fallsBackToLastLines() {
        let stderr = (1 ... 20).map { "line \($0)" }.joined(separator: "\n")

        let lines = BrewError.conciseOutput(stderr).split(separator: "\n")

        #expect(lines.count == 6)
        #expect(lines.last == "line 20")
    }

    @Test("details conserva la salida completa, sin los repintados del medidor")
    func detailsKeepsEverythingButTheMeter() {
        let error = BrewError.commandFailed(
            exitCode: 1,
            stderr: "==> Fetching wget\n###  30.0%\rError: boom\nmore context",
            command: "brew install wget"
        )

        #expect(error.details == "brew install wget\nexit code 1\n==> Fetching wget\nError: boom\nmore context")
    }

    @Test("las descargas completadas (✔︎) no se muestran como motivo del fallo")
    func downloadTicksAreNotTheReason() {
        let stderr = """
        ✔︎ Bottle mlx-c (0.8.0)
        ✔︎ Bottle ollama (0.40.16)
        Warning: The post-install step did not complete successfully
        Warning: The post-install step did not complete successfully
        """

        #expect(BrewError.conciseOutput(stderr) == "Warning: The post-install step did not complete successfully")
    }

    @Test("un post-install fallido dice que el paquete sí se instaló y cuál reintentar")
    func failedPostinstallIsExplained() {
        let error = BrewError.commandFailed(
            exitCode: 1,
            stderr: "✔︎ Bottle ollama (0.40.16)\nWarning: The post-install step did not complete successfully\n"
                + "brew postinstall python@3.15",
            command: "brew upgrade ollama"
        )

        let text = error.localizedDescription

        #expect(text.hasPrefix("Installed, but the post-install step of python@3.15 didn't finish."))
        #expect(text.contains("brew postinstall python@3.15"))
        #expect(BrewError.failedPostinstallNames(in: "You can try again using:\n  brew postinstall python@3.15\n")
            == ["python@3.15"])
    }

    @Test("un comando que se cuelga se explica como tiempo agotado")
    func timedOutNamesTheCommand() {
        let text = BrewError.timedOut(command: "brew update", seconds: 600).localizedDescription

        #expect(text.contains("brew update"))
        #expect(text.contains("600"))
    }
}

@Suite("BrewService — brew doctor")
struct BrewDoctorParsingTests {
    @Test("--json: cada hallazgo llega entero, con su solución")
    func jsonFindingsKeepRemediation() throws {
        let json = """
        {"tier": 1, "findings": [
          {"text": "Some installed formulae are deprecated or disabled.", "tier": 1, "affects": ["icu4c@78"],
           "links": [], "remediation": {"commands": [], "text": "Run:\\n  brew upgrade harfbuzz"}},
          {"text": "Unbrewed dylibs were found.", "tier": 1, "affects": [], "links": [], "remediation": null}
        ]}
        """

        let warnings = try #require(BrewService.parseDoctorJSON(json))

        #expect(warnings.map(\.message) == [
            "Warning: Some installed formulae are deprecated or disabled.\n\nRun:\n  brew upgrade harfbuzz",
            "Warning: Unbrewed dylibs were found.",
        ])
    }

    @Test("--json: un Homebrew sin la opción no devuelve JSON y se cae al texto")
    func nonJSONOutputIsNotAnEmptyReport() {
        #expect(BrewService.parseDoctorJSON("") == nil)
        #expect(BrewService.parseDoctorJSON("Error: invalid option: --json") == nil)
    }

    @Test("texto: un hallazgo con líneas en blanco no se corta en su primer párrafo")
    func textFindingKeepsItsParagraphs() {
        let stderr = """
        Warning: Calling `postflight` is deprecated! Use `postflight_steps` instead.
          /opt/homebrew/Library/Taps/x/homebrew-tap/Casks/y.rb:21

        Please note that these warnings are just used to help the Homebrew maintainers
        with debugging if you file an issue.

        Warning: Some installed formulae are deprecated or disabled.
        The following formulae are installed as dependencies:

          icu4c@78

        Warning: /usr/bin occurs before /opt/homebrew/bin in your PATH.
        """

        let warnings = BrewService.parseDoctorOutput(stderr)

        #expect(warnings.count == 2)
        #expect(warnings[0].message.hasSuffix("icu4c@78"))
        #expect(warnings[1].message.hasPrefix("Warning: /usr/bin"))
    }
}

@Suite("BrewService — un fallo de lectura no es un resultado vacío")
struct BrewSearchFailureTests {
    private let arguments = ["search", "--formula", "--", "wget"]

    @Test("sin coincidencias (exit 1, 'No formulae or casks found') es una lista vacía")
    func noMatchesIsEmpty() throws {
        let result = ProcessResult(exitCode: 1, stdout: "", stderr: "Error: No formulae or casks found for \"zzz\".")

        #expect(try BrewService.searchNames(result, arguments).isEmpty)
    }

    @Test("cualquier otro fallo se propaga con lo que dijo brew")
    func realFailureThrows() async {
        let result = ProcessResult(exitCode: 1, stdout: "", stderr: "Error: Permission denied @ rb_sysopen")

        await expectCommandFailure(1, stderr: "Error: Permission denied @ rb_sysopen") {
            try BrewService.searchNames(result, arguments)
        }
    }
}

@Suite("DashboardViewModel — fallos que antes solo iban al log")
@MainActor
struct DashboardActionFailureTests {
    private func makeViewModel(_ service: MockBrewServiceForDashboard) -> DashboardViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DashboardViewModel(
            service: service,
            apiClient: MockHomebrewAPIService(),
            installedPackagesCache: InstalledPackagesCache(directory: directory)
        )
    }

    @Test("un fallo anterior no hace que una instalación limpia posterior se vea fallida")
    func earlierFailureDoesNotTaintLaterInstall() async throws {
        let service = MockBrewServiceForDashboard()
        await service.setInstallError(BrewError.commandFailed(exitCode: 1, stderr: "Error: boom"))
        let vm = makeViewModel(service)

        vm.installSingle(name: "broken", isCask: false)
        try await waitUntil { !vm.isInstallRunning }
        #expect(vm.installSessionFailures.map(\.name) == ["broken"])
        vm.dismissInstallSheet()

        await service.setInstallError(nil)
        vm.installSingle(name: "wget", isCask: false)
        try await waitUntil { !vm.isInstallRunning }

        #expect(vm.installSessionFailures.isEmpty)
        #expect(vm.failedInstallNames == ["broken"])
    }

    @Test("tras Cancelar, la hoja sigue en 'cancelando' hasta que brew termina de verdad")
    func cancellingLastsUntilTheInstallHasStopped() async throws {
        let service = MockBrewServiceForDashboard()
        await service.setInstallDelay(300_000_000)
        let vm = makeViewModel(service)

        vm.installSingle(name: "wget", isCask: false)
        try await waitUntil { await service.installCalls.count == 1 }
        vm.cancelInstall()

        #expect(vm.isCancellingInstall)
        try await waitUntil { !vm.isCancellingInstall }
        #expect(!vm.isInstallRunning)
    }

    /// Regression: a cancel records no failure, so the sheet ended on a green "Done".
    @Test("una instalación cancelada termina como cancelada, y la siguiente empieza limpia")
    func cancelledInstallSaysSo() async throws {
        let service = MockBrewServiceForDashboard()
        await service.setInstallDelay(300_000_000)
        let vm = makeViewModel(service)

        vm.installSingle(name: "wget", isCask: false)
        try await waitUntil { await service.installCalls.count == 1 }
        vm.cancelInstall()
        try await waitUntil { !vm.isCancellingInstall }

        #expect(vm.installPhase == .cancelled)
        #expect(vm.installSessionFailures.isEmpty)

        vm.dismissInstallSheet()
        await service.setInstallDelay(0)
        vm.installSingle(name: "jq", isCask: false)
        #expect(vm.installPhase == .running)
        try await waitUntil { !vm.isInstallRunning }
        #expect(vm.installPhase == .done)
    }

    @Test("un paquete de un tap de terceros (brew outdated lo nombra completo) cuenta y se marca como desactualizado")
    func tapQualifiedOutdatedNameStaysInSync() {
        let service = MockBrewServiceForDashboard()
        let menuBar = MenuBarViewModel(service: MockBrewService())
        menuBar.store.applyOutdated([
            OutdatedPackage(
                name: "cameroncooke/axe/axe",
                installedVersions: ["1.0"],
                currentVersion: "2.0",
                pinned: false
            ),
            OutdatedPackage(name: "wget", installedVersions: ["1.0"], currentVersion: "2.0", pinned: false),
        ])
        let vm = DashboardViewModel(
            service: service,
            apiClient: MockHomebrewAPIService(),
            store: menuBar.store
        )

        #expect(vm.outdatedInstalledCount == menuBar.outdatedPackages.count)
        #expect(vm.isOutdated("axe"))
    }

    @Test("removeTap() que falla deja el motivo y el detalle copiable para la alerta")
    func removeTapFailureReachesTheUI() async {
        let service = MockBrewServiceForDashboard()
        await service.setRemoveTapError(
            BrewError.commandFailed(exitCode: 1, stderr: "Error: not tapped", command: "brew untap a/b")
        )
        let vm = makeViewModel(service)

        await vm.removeTap("a/b")

        #expect(vm.actionFailure?.message.contains("not tapped") == true)
        #expect(vm.actionFailure?.details == "brew untap a/b\nexit code 1\nError: not tapped")
    }
}

@Suite("LocalPackageIndex — búsqueda sin lanzar brew")
struct LocalPackageIndexTests {
    /// A Homebrew cache with name lists, and a repository with one third-party tap.
    private func makeFixture() throws -> (index: LocalPackageIndex, repository: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let api = root.appendingPathComponent("cache/api")
        let tap = root.appendingPathComponent("repo/Library/Taps/dotfn/homebrew-tap")
        for directory in [api, tap.appendingPathComponent("Casks"), tap.appendingPathComponent("Formula")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "wget\nwget2\nnode\ngcc@13\n".write(
            to: api.appendingPathComponent("formula_names.txt"), atomically: true, encoding: .utf8
        )
        try "wgetter-app\niterm2\n".write(
            to: api.appendingPathComponent("cask_names.txt"), atomically: true, encoding: .utf8
        )
        try "".write(to: tap.appendingPathComponent("Casks/lumus-control.rb"), atomically: true, encoding: .utf8)
        try "".write(to: tap.appendingPathComponent("Formula/wget-extra.rb"), atomically: true, encoding: .utf8)
        return (LocalPackageIndex(apiDirectory: api), root.appendingPathComponent("repo").path)
    }

    @Test("encuentra fórmulas, casks y paquetes de taps de terceros, con el nombre que da brew search")
    func findsOfficialAndTappedPackages() throws {
        let (index, repository) = try makeFixture()

        let results = try #require(index.search("wget", repository: repository))

        #expect(Set(results.map(\.name)) == ["wget", "wget2", "wgetter-app", "dotfn/tap/wget-extra"])
        #expect(results.first { $0.name == "wgetter-app" }?.isCask == true)
        #expect(index.search("lumus", repository: repository)?.map(\.name) == ["dotfn/tap/lumus-control"])
    }

    @Test("compara como brew: sin mayúsculas ni puntuación, pero @ cuenta")
    func matchesLikeBrew() throws {
        let (index, repository) = try makeFixture()

        #expect(index.search("ITerm-2", repository: repository)?.map(\.name) == ["iterm2"])
        #expect(index.search("gcc@13", repository: repository)?.map(\.name) == ["gcc@13"])
    }

    @Test("sin listas o con una /regex/ no responde, y busca brew")
    func declinesWhatItCannotAnswer() throws {
        let (index, repository) = try makeFixture()
        let missing = LocalPackageIndex(apiDirectory: URL(fileURLWithPath: "/nonexistent/api"))

        #expect(missing.search("wget", repository: repository) == nil)
        #expect(index.search("/^wget/", repository: repository) == nil)
    }
}

@Suite("SystemProcessRunner — lanzamiento", .serialized, .timeLimit(.minutes(2)))
struct SystemProcessRunnerSpawnTests {
    @Test("devuelve el código de salida del comando")
    func reportsExitCode() async throws {
        let result = try await SystemProcessRunner().run(
            executablePath: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 7"], environment: [:]
        )

        #expect(result.exitCode == 7)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
    }

    @Test("un ejecutable que no existe es un error, no un resultado")
    func missingExecutableThrows() async {
        await #expect(throws: POSIXError.self) {
            _ = try await SystemProcessRunner().run(
                executablePath: "/nonexistent/brew",
                arguments: [],
                environment: [:]
            )
        }
    }

    @Test("el comando no hereda stdin ni deja descriptores abiertos tras cada ejecución")
    func leavesNoDescriptorsBehind() async throws {
        func openDescriptors() -> Int {
            (0 ..< 1024).count(where: { fcntl(Int32($0), F_GETFD) != -1 })
        }
        let runner = SystemProcessRunner()
        _ = try await runner.runStreaming(executablePath: "/bin/cat", arguments: [], environment: [:], onLine: { _ in })
        let before = openDescriptors()

        for _ in 0 ..< 40 {
            // `cat` with no arguments reads stdin: it only returns because stdin is /dev/null.
            _ = try await runner.run(executablePath: "/bin/cat", arguments: [], environment: [:])
            _ = try await runner.runStreaming(
                executablePath: "/bin/cat",
                arguments: [],
                environment: [:],
                onLine: { _ in }
            )
        }

        #expect(openDescriptors() <= before + 2)
    }
}

@Suite("EnvironmentResolver — espera cancelable")
struct EnvironmentResolverCancellableWaitTests {
    @Test("cancelar a quien espera lo libera, aunque nadie configure nunca")
    func cancelledWaiterIsReleased() async {
        let resolver = EnvironmentResolver()
        let waiter = Task { try await resolver.waitUntilConfigured() }
        try? await Task.sleep(for: .milliseconds(50))

        waiter.cancel()

        await #expect(throws: CancellationError.self) { try await waiter.value }
    }
}
