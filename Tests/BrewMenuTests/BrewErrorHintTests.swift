import BrewCore
@testable import BrewMenu
import Foundation
import Testing

@Suite("BrewError — pistas accionables")
struct BrewErrorHintTests {
    /// Regression coverage: raw stderr used to be the only text, so a permissions or lock
    /// failure read like a cryptic log line. The raw text must stay under the hint.
    @Test("un fallo de permisos muestra una pista y conserva el texto original")
    func permissionHintKeepsRawText() {
        let error = BrewError.commandFailed(exitCode: 1, stderr: "Error: Permission denied @ rb_sysopen")
        let text = error.localizedDescription
        #expect(text.contains("permission"))
        #expect(text.contains("Permission denied @ rb_sysopen"))
    }

    @Test("un lock de Homebrew se explica como 'espera y reintenta'")
    func lockHint() {
        let text = BrewError.commandFailed(
            exitCode: 1,
            stderr: "Error: Another active Homebrew process is already using this prefix"
        ).localizedDescription
        #expect(text.contains("Another Homebrew command is still running") || text.contains("Otro comando de Homebrew"))
    }

    @Test("un error no reconocido queda exactamente igual")
    func unknownErrorUnchanged() {
        let text = BrewError.commandFailed(exitCode: 1, stderr: "something else entirely").localizedDescription
        #expect(text == "Command failed (code 1): something else entirely" || text ==
            "Comando fallido (código 1): something else entirely")
    }

    @Test("friendlyHint devuelve nil cuando no hay patrón conocido")
    func noHintForUnknown() {
        #expect(BrewError.friendlyHint(for: "unrelated output") == nil)
    }

    /// Each in brew's own wording (Homebrew's source and its `sudo` wrapper).
    @Test("los fallos frecuentes sin pista hasta ahora tienen una", arguments: [
        ("sudo: a password is required", "password wasn't entered", "No se introdujo la contraseña"),
        ("sudo: 3 incorrect password attempts", "password was wrong", "no era correcta"),
        (
            "Error: Cannot change the ownership of '/Applications/Foo.app' because your terminal does not have App Management permissions.",
            "App Management",
            "Gestión de apps"
        ),
        (
            "Error: It seems there is already an App at '/Applications/Foo.app'.",
            "already in Applications",
            "Aplicaciones"
        ),
        ("Error: SHA-256 mismatch\nExpected: abc\n  Actual: def", "didn't match", "no coincide"),
        ("Error: Your Command Line Tools are too outdated.", "Command Line Tools", "Command Line Tools"),
    ])
    func newHints(stderr: String, english: String, spanish: String) throws {
        let hint = try #require(BrewError.friendlyHint(for: stderr))
        #expect(hint.contains(english) || hint.contains(spanish))
    }

    /// Regression: with no "Error:" line, the reason shown was the first "Warning:" — on a Mac with a
    /// tap using a deprecated DSL, a notice about an unrelated cask.
    @Test("los avisos de deprecación de un tap no se muestran como motivo del fallo")
    func tapDeprecationNoticeIsNotTheReason() {
        let stderr = """
        Warning: Calling `postflight` is deprecated! Use `postflight_steps` instead.
        Please report this issue to the dotfn/homebrew-tap tap (not Homebrew/* repositories), or even better, submit a PR to fix it:
          /opt/homebrew/Library/Taps/dotfn/homebrew-tap/Casks/lumus-control.rb:21
        Warning: The post-install step did not complete successfully
        """

        #expect(BrewError.conciseOutput(stderr) == "Warning: The post-install step did not complete successfully")
    }

    @Test("un error real que nombra un archivo de un tap no se toma por un aviso de deprecación")
    func realErrorNamingATapFileStays() {
        let stderr = "Error: Cask 'foo' is unreadable: /opt/homebrew/Library/Taps/user/homebrew-tap/Casks/foo.rb:3"

        #expect(BrewError.conciseOutput(stderr) == stderr)
    }

    @Test("si solo hay avisos de deprecación, se muestran igualmente")
    func onlyNoticesStillShowSomething() {
        let stderr = "Warning: Calling `postflight` is deprecated! Use `postflight_steps` instead."

        #expect(BrewError.conciseOutput(stderr) == stderr)
    }
}

/// "Copy error" hands over the command, the exit code and brew's output, so a report can say
/// exactly what ran.
@Suite("BrewError — detalles copiables")
struct BrewErrorDetailsTests {
    @Test("details incluye el comando, el código de salida y el stderr")
    func detailsCarryCommandCodeAndOutput() {
        let error = BrewError.commandFailed(
            exitCode: 2,
            stderr: "Error: no bottle",
            command: BrewError.commandLine(["install", "wget"])
        )
        #expect(error.details == "brew install wget\nexit code 2\nError: no bottle")
    }

    @Test("un error sin comando conserva el texto de siempre")
    func detailsWithoutCommandFallBack() {
        let error = BrewError.commandFailed(exitCode: 1, stderr: "boom")
        #expect(error.details.hasPrefix("brew\nexit code 1\nboom"))
    }

    @Test("un fallo real de upgrade lleva los nombres de los paquetes que se intentaron")
    func realUpgradeFailureNamesThePackages() async throws {
        let runner = MockProcessRunner()
        runner.responses = [
            ProcessResult(exitCode: 0, stdout: shellenvOutputForTests, stderr: ""),
            ProcessResult(exitCode: 1, stdout: "", stderr: "Error: Permission denied"),
        ]
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: ["/opt/homebrew/bin/brew"]))
        let service = BrewService(resolver: resolver, runner: runner)
        try await service.bootstrap()

        do {
            try await service.runUpgradeAll(names: ["wget", "git"], onLine: { _ in })
            Issue.record("se esperaba un error")
        } catch let error as BrewError {
            #expect(error.details.hasPrefix("brew upgrade wget git"))
        }
    }
}

private let shellenvOutputForTests = """
export HOMEBREW_PREFIX="/opt/homebrew";
export HOMEBREW_CELLAR="/opt/homebrew/Cellar";
export PATH="/opt/homebrew/bin:/usr/bin:/bin";
"""

/// A saved brew path that no longer runs is ignored at launch, so the app falls back to detection.
@Suite("EnvironmentResolver — ruta guardada")
struct SavedBrewPathTests {
    @Test("una ruta guardada que ya no es ejecutable se ignora")
    func staleSavedPathIsIgnored() {
        #expect(EnvironmentResolver.usableCustomPath("/gone/brew") { _ in false } == nil)
    }

    @Test("una ruta guardada que sí ejecuta se conserva")
    func runnableSavedPathIsKept() {
        #expect(EnvironmentResolver
            .usableCustomPath("/opt/homebrew/bin/brew") { $0 == "/opt/homebrew/bin/brew" } == "/opt/homebrew/bin/brew")
    }

    @Test("sin ruta guardada no hay nada que usar")
    func noSavedPath() {
        #expect(EnvironmentResolver.usableCustomPath(nil) { _ in true } == nil)
    }
}
