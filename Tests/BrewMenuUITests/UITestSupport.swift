import Foundation
import XCTest

/// Everything a UI test needs to run BrewMenu without touching the real machine: a throwaway data
/// folder, onboarding already done, and a fake `brew` script that answers the commands the app sends
/// and records what would have been upgraded. Nothing here calls the real Homebrew.
struct UITestEnvironment {
    let data: URL
    /// The committed fake brew. A file from git has no provenance attribute, so the app can run it;
    /// a script the test runner wrote itself is refused with "Operation not permitted".
    let brew: URL
    var upgradeMarker: URL { data.appendingPathComponent("upgraded.txt") }

    static func make() throws -> UITestEnvironment {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = data.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let brew = fixtures.appendingPathComponent("fake-brew")
        // Only the path matters: every other setting decodes from its default.
        let settings = "{\"customBrewPath\": \"\(brew.path)\"}"
        try settings.write(to: support.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        return UITestEnvironment(data: data, brew: brew)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: data)
    }

    /// The app, launched against this environment.
    func launchApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.brewmenu.app")
        // The override is the root: the app puts settings under <root>/support itself.
        app.launchEnvironment["BREWMENU_DATA_DIR"] = data.path
        app.launchEnvironment["BREWMENU_FAKE_ROOT"] = data.path
        app.launchArguments = ["-hasCompletedOnboarding", "YES"]
        app.launch()
        return app
    }
}
