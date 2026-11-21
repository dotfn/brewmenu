@testable import BrewMenu
import Foundation
import Testing

@Suite("SudoTouchID — si sudo acepta Touch ID en este Mac")
struct SudoTouchIDTests {
    private func file(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sudo_local-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("una línea de pam_tid activa lo detecta; comentada, no", arguments: [
        ("auth       sufficient     pam_tid.so", true),
        ("auth\tsufficient\tpam_tid.so", true),
        ("auth sufficient /usr/lib/pam/pam_tid.so.2", true),
        ("auth required pam_tid.so # Touch ID only", true),
        ("#auth       sufficient     pam_tid.so", false),
        ("  # auth sufficient pam_tid.so", false),
        ("auth       sufficient     pam_smartcard.so", false),
        ("account    required       pam_tid.so", false),
        ("auth sufficient pam_tid_extra.so", false),
    ])
    func line(text: String, enabled: Bool) {
        #expect(SudoTouchID.usesTouchID(text) == enabled)
    }

    @Test("el sudo_local que trae macOS, con todo comentado, no activa Touch ID")
    func shippedFileIsOff() throws {
        let shipped = try file("""
        # sudo_local: local config file which survives system update and is included for sudo
        # uncomment following line to enable Touch ID for sudo
        #auth       sufficient     pam_tid.so
        """)
        defer { try? FileManager.default.removeItem(at: shipped) }
        #expect(!SudoTouchID.isEnabled(configurationFiles: [shipped]))
    }

    @Test("con la línea descomentada en cualquiera de los archivos, sí")
    func enabledInEitherFile() throws {
        let off = try file("auth required pam_opendirectory.so\n")
        let on = try file("# local\nauth       sufficient     pam_tid.so\n")
        defer { [off, on].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(SudoTouchID.isEnabled(configurationFiles: [off, on]))
        #expect(!SudoTouchID.isEnabled(configurationFiles: [off]))
    }

    @Test("un archivo que no existe cuenta como sin Touch ID: el diálogo de contraseña se queda")
    func missingFileIsOff() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        #expect(!SudoTouchID.isEnabled(configurationFiles: [missing]))
    }
}
