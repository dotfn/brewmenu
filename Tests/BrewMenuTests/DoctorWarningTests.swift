import BrewCore
@testable import BrewMenu
import Foundation
import Testing

/// From a real `brew doctor --json` run, trimmed to three findings and a shorter script path.
private let doctorJSON = #"""
{"tier": 1, "findings": [
  {"text": "Some installed formulae are deprecated or disabled.", "tier": 1, "affects": ["icu4c@78"], "links": [],
   "remediation": {"commands": [], "text": "The following formulae are installed as dependencies:\n\n  icu4c@78\n\nTo stop the listed dependents from requiring the formulae above, run:\n  brew upgrade postgresql@18"}},
  {"text": "Root certificates in /etc/ssl/cert.pem can trust compromised CAs.\nCommand-line tools using this file may accept forged TLS certificates:\n  AAA Certificate Services\n  emSign ECC Root CA - G3\n",
   "tier": 1, "affects": [], "links": ["https://support.apple.com/en-us/149555"],
   "remediation": {"commands": [], "text": "Run this script to create a backup and remove these roots:\n  sudo /opt/homebrew/Library/Homebrew/utils/emudhra_certificates.rb\n\nThe script validates the bundle before replacing it. Removing the roots\ncan break HTTPS connections to some websites.\n\nFor details and software update plans, see:\n  https://support.apple.com/en-us/149555\n"}},
  {"text": "/usr/bin occurs before /opt/homebrew/bin in your PATH.\nThis means that system-provided programs will be used instead of those\nprovided by Homebrew.\n",
   "tier": 1, "affects": [], "links": [],
   "remediation": {"commands": ["printf '%s\\n' export\\ PATH\\=/opt/homebrew/bin:\\$PATH >> ~/.zshrc"], "text": "Consider setting your PATH for example like so:\n  printf '%s\\n' export\\ PATH\\=/opt/homebrew/bin:\\$PATH >> ~/.zshrc\n"}}
]}
"""#

@Suite("DoctorWarning — el hallazgo por partes")
struct DoctorWarningTests {
    /// Regression: the parts were joined into one message and the row cut it at three lines, so the
    /// fix — the command to run — was the part that never showed.
    @Test("--json: título, solución, comandos, paquetes y enlaces quedan por separado")
    func jsonKeepsTheParts() throws {
        let warnings = try #require(BrewService.parseDoctorJSON(doctorJSON))
        try #require(warnings.count == 3)

        let deprecated = warnings[0]
        #expect(deprecated.title == "Some installed formulae are deprecated or disabled.")
        #expect(deprecated.detail == nil)
        #expect(deprecated.affectedPackages == ["icu4c@78"])
        #expect(deprecated.commands == ["brew upgrade postgresql@18"])
        #expect(deprecated.fixSteps == [
            .text("""
            The following formulae are installed as dependencies:

              icu4c@78

            To stop the listed dependents from requiring the formulae above, run:
            """),
            .command("brew upgrade postgresql@18"),
        ])

        let certificates = warnings[1]
        #expect(certificates.title == "Root certificates in /etc/ssl/cert.pem can trust compromised CAs.")
        #expect(certificates.detail == """
        Command-line tools using this file may accept forged TLS certificates:
          AAA Certificate Services
          emSign ECC Root CA - G3
        """)
        #expect(certificates.commands == ["sudo /opt/homebrew/Library/Homebrew/utils/emudhra_certificates.rb"])
        // Listed by brew and repeated in the prose: one link, not two.
        #expect(certificates.links == [URL(string: "https://support.apple.com/en-us/149555")])
        // Regression: the command was listed after all the prose, right under "…see:", so it read
        // as the thing to see. Each step stays where brew puts it, with the 80-column wrap undone.
        let address = try #require(URL(string: "https://support.apple.com/en-us/149555"))
        #expect(certificates.fixSteps == [
            .text("Run this script to create a backup and remove these roots:"),
            .command("sudo /opt/homebrew/Library/Homebrew/utils/emudhra_certificates.rb"),
            .text("""
            The script validates the bundle before replacing it. Removing the roots can break HTTPS connections to some websites.

            For details and software update plans, see:
            """),
            .link(address),
        ])

        let path = warnings[2]
        #expect(path.title == "/usr/bin occurs before /opt/homebrew/bin in your PATH.")
        #expect(path.detail == """
        This means that system-provided programs will be used instead of those provided by Homebrew.
        """)
        #expect(path.commands == [#"printf '%s\n' export\ PATH\=/opt/homebrew/bin:\$PATH >> ~/.zshrc"#])
        #expect(path.fixSteps == [
            .text("Consider setting your PATH for example like so:"),
            .command(#"printf '%s\n' export\ PATH\=/opt/homebrew/bin:\$PATH >> ~/.zshrc"#),
        ])
        #expect(path.concernsPATH)
    }

    @Test("texto: el título junta las líneas que brew partió a 80 columnas y saca el comando")
    func textTitleSpansWrappedLines() {
        let warning = DoctorWarning(severity: .warning, message: """
        Warning: Homebrew's "sbin" was not found in your PATH but you have installed
        formulae that put executables in /opt/homebrew/sbin.
        Consider setting your PATH for example like so:
          echo 'export PATH="/opt/homebrew/sbin:$PATH"' >> ~/.zshrc
        """)

        #expect(warning.title == """
        Homebrew's "sbin" was not found in your PATH but you have installed formulae that put executables in /opt/homebrew/sbin.
        """)
        #expect(warning.commands == [#"echo 'export PATH="/opt/homebrew/sbin:$PATH"' >> ~/.zshrc"#])
        #expect(warning.detail == "Consider setting your PATH for example like so:")
    }

    @Test("un aviso guardado en el historial antes de este cambio se sigue leyendo")
    func decodesOldSnapshots() throws {
        let saved = #"{"severity": "warning", "message": "Warning: Unbrewed dylibs were found.\n\nRun:\n  brew cleanup"}"#

        let warning = try JSONDecoder().decode(DoctorWarning.self, from: Data(saved.utf8))

        #expect(warning.message == "Warning: Unbrewed dylibs were found.\n\nRun:\n  brew cleanup")
        #expect(warning.title == "Unbrewed dylibs were found.")
        #expect(warning.commands == ["brew cleanup"])
    }

    @Test("la nota del PATH solo sale cuando el hallazgo habla del PATH, no de LIBRARY_PATH")
    func pathNoteMatchesTheWordOnly() {
        let path = DoctorWarning(severity: .warning, message: "Warning: /usr/bin comes before Homebrew in your PATH.")
        let library = DoctorWarning(severity: .warning, message: "Warning: DYLD_LIBRARY_PATH can break linking.")

        #expect(path.concernsPATH)
        #expect(!library.concernsPATH)
    }

    @Test("guardar y volver a leer un aviso no pierde ninguna parte")
    func roundTrips() throws {
        let warnings = try #require(BrewService.parseDoctorJSON(doctorJSON))

        let decoded = try JSONDecoder().decode([DoctorWarning].self, from: JSONEncoder().encode(warnings))

        #expect(decoded == warnings)
    }
}

@Suite("BrewStore — brew doctor bajo demanda")
@MainActor
struct DoctorOnDemandTests {
    /// Regression: doctor only ran from the scheduled check — an hour after launch, then daily — so a
    /// fix stayed listed for up to a day, and the page said "no warnings" before it had ever run.
    @Test("Check Again ejecuta brew doctor y fecha el resultado")
    func runDoctorDatesTheResult() async throws {
        let service = MockBrewService()
        await service.setDoctorResponse([DoctorWarning(severity: .warning, message: "Warning: Something is off.")])
        let vm = MenuBarViewModel(service: service)
        #expect(vm.doctorPage == .notChecked)

        vm.runDoctor()
        #expect(vm.doctorPage == .running)
        vm.runDoctor()
        try await waitUntil { !vm.isRunningDoctor }

        #expect(vm.doctorPage == .checked)
        #expect(vm.doctorCheckedAt != nil)
        #expect(vm.visibleDoctorWarnings.map(\.title) == ["Something is off."])
        #expect(!vm.doctorFoundNothing)
        #expect(await service.doctorCallCount == 1)
    }

    @Test("una ejecución ya en marcha (la del arranque) no se duplica")
    func runDoctorWhileRunningIsANoOp() async throws {
        let service = MockBrewService()
        await service.setHoldsDoctor(true)
        let store = BrewStore(service: service)
        let launch = Task { await store.runDoctor() }
        try await waitUntil { await service.isDoctorHeld }

        await store.runDoctor()
        await service.releaseDoctor()
        await launch.value

        #expect(await service.doctorCallCount == 1)
    }

    @Test("sin advertencias tras una ejecución real, la página puede decir que no hay problemas")
    func emptyRunIsAnAllClear() async {
        let vm = MenuBarViewModel(service: MockBrewService())

        await vm.store.runDoctor()

        #expect(vm.doctorPage == .checked)
        #expect(vm.doctorFoundNothing)
    }

    @Test("si brew doctor falla antes de su primera ejecución, no queda como 'sin advertencias'")
    func failedFirstRunIsNotAnAllClear() async {
        let service = MockBrewService()
        await service.setDoctorError(BrewError.timedOut(command: "brew doctor", seconds: 300))
        let vm = MenuBarViewModel(service: service)

        await vm.store.runDoctor()

        #expect(vm.doctorPage == .failed(vm.doctorFailure ?? ""))
        #expect(vm.doctorFailure != nil)
        #expect(!vm.doctorFoundNothing)
    }
}

@Suite("Diálogo de contraseña y vuelta al Dashboard")
@MainActor
struct AskpassTests {
    /// The translations land inside an AppleScript string inside a single-quoted shell word.
    @Test("el script es shell válido aunque la traducción lleve comillas y barras")
    func scriptStaysValidShell() throws {
        let script = BrewService.askpassScript(
            message: #"BrewMenu's "admin" password \ please"#,
            cancel: "Cancel",
            ok: "OK",
            notification: "com.brewmenu.test.askpass-finished"
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("askpass-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", url.path]
        try check.run()
        check.waitUntilExit()

        #expect(check.terminationStatus == 0)
        // Tells BrewMenu, instead of reopening it like a Dock click would (`open -b`).
        #expect(script.contains("/usr/bin/notifyutil -p com.brewmenu.test.askpass-finished"))
        let commands = script.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(!commands.contains { $0.contains("open -b") })
    }

    /// Regression: reopening the app sent an open Dashboard back to Discover.
    @Test("reabrir la app deja el Dashboard abierto donde estaba")
    func reopenKeepsTheOpenSection() {
        let navigation = DashboardNavigation()
        navigation.selectedSection = .doctorWarnings
        #expect(navigation.sectionForReopen == .home)

        navigation.isWindowOpen = true

        #expect(navigation.sectionForReopen == .doctorWarnings)
    }
}

@Suite("Avisos de doctor ignorados")
@MainActor
struct IgnoredDoctorWarningTests {
    @Test("un aviso ignorado deja de contar para el icono y el popover, pero sigue en la página")
    func ignoredWarningLeavesTheIcon() async {
        let service = MockBrewService()
        await service.setDoctorResponse([DoctorWarning(severity: .warning, message: "Warning: Something is off.")])
        let vm = MenuBarViewModel(service: service)
        vm.store.applyOutdated([])
        await vm.store.runDoctor()
        #expect(vm.status == .warning(count: 1))

        vm.store.setIgnoredDoctorTitles(["Something is off."])

        #expect(vm.status == .ok)
        #expect(vm.visibleDoctorWarnings.isEmpty)
        #expect(vm.ignoredDoctorWarnings.map(\.title) == ["Something is off."])
        // Not "no warnings": the Ignored list is where it's brought back from.
        #expect(!vm.doctorFoundNothing)
    }

    @Test("ignorar llega al almacén en el acto y se guarda para la próxima vez")
    func ignoringReachesTheStoreAndPersists() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let settings = try makeSettings(in: dir)
        let store = BrewStore(service: MockBrewService())
        settings.bindIgnoredDoctorWarnings(to: store)

        settings.ignoreDoctorWarning(titled: "Something is off.")
        #expect(store.ignoredDoctorTitles == ["Something is off."])

        await settings.save()
        #expect(await SettingsStore(directory: dir).settings.ignoredDoctorWarnings == ["Something is off."])

        settings.stopIgnoringDoctorWarning(titled: "Something is off.")
        #expect(store.ignoredDoctorTitles.isEmpty)
    }

    @Test("al arrancar, la lista guardada llega al almacén con load()")
    func savedListReachesTheStoreOnLaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var saved = AppSettings()
        saved.ignoredDoctorWarnings = ["Something is off."]
        try await SettingsStore(directory: dir).save(saved)
        let settings = try makeSettings(in: dir)
        let store = BrewStore(service: MockBrewService())

        settings.bindIgnoredDoctorWarnings(to: store)
        await settings.load()

        #expect(store.ignoredDoctorTitles == ["Something is off."])
    }

    private func makeSettings(in dir: URL) throws -> SettingsViewModel {
        try SettingsViewModel(
            store: SettingsStore(directory: dir),
            checker: StatusChecker(store: BrewStore(service: MockBrewService())),
            notifier: BrewNotifier(),
            defaults: #require(UserDefaults(suiteName: "IgnoredDoctorWarningTests.\(UUID().uuidString)")),
            isLaunchAtLoginEnabled: { false }
        )
    }

    @Test("un settings.json anterior a la opción se sigue leyendo, sin nada ignorado")
    func oldSettingsDecode() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"showUpdateBadge": false}"#.utf8))

        #expect(settings.ignoredDoctorWarnings.isEmpty)
        #expect(!settings.showUpdateBadge)
    }
}

@Suite("Arreglos de brew doctor desde la app")
@MainActor
struct DoctorFixTests {
    @Test("solo un comando brew simple se ejecuta desde la app; sudo, shell y sintaxis de shell no")
    func whichCommandsRun() {
        #expect(DoctorWarning.brewArguments(of: "brew upgrade postgresql@18") == ["upgrade", "postgresql@18"])
        #expect(DoctorWarning.brewArguments(of: "brew link --overwrite node@22") == ["link", "--overwrite", "node@22"])
        #expect(DoctorWarning.brewArguments(of: "sudo /opt/homebrew/utils/emudhra_certificates.rb") == nil)
        #expect(DoctorWarning.brewArguments(of: #"printf '%s\n' export\ PATH >> ~/.zshrc"#) == nil)
        #expect(DoctorWarning.brewArguments(of: "brew upgrade x; rm -rf ~") == nil)
        #expect(DoctorWarning.brewArguments(of: "brew upgrade $(whoami)") == nil)

        #expect(MenuBarViewModel.canRunDoctorFix("brew upgrade postgresql@18"))
        // A plain brew command, but not one of the kinds BrewMenu runs.
        #expect(!MenuBarViewModel.canRunDoctorFix("brew update-reset"))
        #expect(!MenuBarViewModel.canRunDoctorFix("sudo brew upgrade x"))
    }

    @Test("un arreglo que funciona vuelve a pasar brew doctor, sin Check Again")
    func successfulFixChecksAgain() async throws {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)

        vm.runDoctorFix("brew upgrade postgresql@18")
        #expect(vm.runningDoctorFix == "brew upgrade postgresql@18")
        try await waitUntil { vm.runningDoctorFix == nil }

        #expect(await service.doctorFixCalls == [["upgrade", "postgresql@18"]])
        #expect(await service.doctorCallCount == 1)
        #expect(vm.doctorFixFailure == nil)
    }

    @Test("un arreglo que falla deja el motivo junto a su comando y no vuelve a comprobar")
    func failedFixShowsWhy() async throws {
        let service = MockBrewService()
        await service.setDoctorFixError(BrewError.commandFailed(exitCode: 1, stderr: "Error: nope"))
        let vm = MenuBarViewModel(service: service)

        vm.runDoctorFix("brew upgrade postgresql@18")
        try await waitUntil { vm.runningDoctorFix == nil }

        #expect(vm.doctorFixFailure?.command == "brew upgrade postgresql@18")
        #expect(await service.doctorCallCount == 0)
    }

    @Test("un comando que no se ejecuta desde la app no llega a brew")
    func commandForTerminalNeverRuns() async {
        let service = MockBrewService()
        let vm = MenuBarViewModel(service: service)

        vm.runDoctorFix("sudo /opt/homebrew/utils/emudhra_certificates.rb")

        #expect(vm.runningDoctorFix == nil)
        #expect(await service.doctorFixCalls.isEmpty)
        #expect(MenuBarViewModel.whyDoctorFixIsForTerminal("sudo /x").contains("administrator")
            || MenuBarViewModel.whyDoctorFixIsForTerminal("sudo /x").contains("administrador"))
    }
}

@Suite("Arreglos de brew doctor — paquetes que ya no usa nadie")
@MainActor
struct UnusedAffectedPackageTests {
    /// Real case: after upgrading postgresql@18 (now on icu4c@79), brew doctor only said to "find
    /// replacements" for icu4c@78 — a deprecated dependency nothing used any more.
    private let finding = DoctorWarning(
        finding: "Some installed formulae are deprecated or disabled.",
        remediation: "You should find replacements for the following formulae:\n\n  icu4c@78",
        affectedPackages: ["icu4c@78"]
    )

    @Test("un paquete afectado que ya no usa nadie trae su desinstalación, ejecutable desde la app")
    func unusedPackageGetsARemovalStep() async {
        let service = MockBrewService()
        await service.setAutoremoveDryRunResponse(["icu4c@78"])
        let vm = MenuBarViewModel(service: service)
        await vm.store.refresh([.autoremove])

        let steps = vm.fixSteps(for: finding)

        #expect(steps.last == .command("brew uninstall icu4c@78"))
        #expect(MenuBarViewModel.canRunDoctorFix("brew uninstall icu4c@78"))
    }

    @Test("si algo lo usa todavía, solo quedan los pasos de brew")
    func packageInUseKeepsBrewsSteps() {
        let vm = MenuBarViewModel(service: MockBrewService())

        #expect(vm.fixSteps(for: finding) == finding.fixSteps)
    }

    @Test("tras un upgrade se vuelve a mirar qué dependencias han quedado sin uso")
    func upgradeRefreshesUnusedDependencies() {
        #expect(BrewStore.scopes(after: .upgrade).contains(.autoremove))
    }
}
