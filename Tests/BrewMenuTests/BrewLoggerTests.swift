import Testing
import Foundation
@testable import BrewMenu

@Suite("BrewLogger")
struct BrewLoggerTests {
    // Regression: "Reset All Data" removes the logs folder. The logger then wrote to a path
    // whose folder was gone, and every line after the reset was silently dropped until relaunch.
    @Test("sigue escribiendo tras borrarse su carpeta")
    func keepsWritingAfterFolderIsRemoved() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logger = BrewLogger(directory: dir)
        await logger.log("first")
        try FileManager.default.removeItem(at: dir)

        await logger.log("after reset")

        let contents = try String(contentsOf: dir.appendingPathComponent("brewmenu.log"), encoding: .utf8)
        #expect(contents.contains("after reset"))
    }
}
