import Testing
import Foundation
@testable import BrewMenu

@Suite("BrewError — pistas accionables")
struct BrewErrorHintTests {
    // Regression coverage: raw stderr used to be the only text, so a permissions or lock
    // failure read like a cryptic log line. The raw text must stay under the hint.
    @Test("un fallo de permisos muestra una pista y conserva el texto original")
    func permissionHintKeepsRawText() {
        let error = BrewError.commandFailed(exitCode: 1, stderr: "Error: Permission denied @ rb_sysopen")
        let text = error.localizedDescription
        #expect(text.contains("permission"))
        #expect(text.contains("Permission denied @ rb_sysopen"))
    }

    @Test("un lock de Homebrew se explica como 'espera y reintenta'")
    func lockHint() {
        let text = BrewError.commandFailed(exitCode: 1, stderr: "Error: Another active Homebrew process is already using this prefix").localizedDescription
        #expect(text.contains("Another Homebrew command is still running") || text.contains("Otro comando de Homebrew"))
    }

    @Test("un error no reconocido queda exactamente igual")
    func unknownErrorUnchanged() {
        let text = BrewError.commandFailed(exitCode: 1, stderr: "something else entirely").localizedDescription
        #expect(text == "Command failed (code 1): something else entirely" || text == "Comando fallido (código 1): something else entirely")
    }

    @Test("friendlyHint devuelve nil cuando no hay patrón conocido")
    func noHintForUnknown() {
        #expect(BrewError.friendlyHint(for: "unrelated output") == nil)
    }
}
