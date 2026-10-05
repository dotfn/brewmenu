import XCTest

/// The smallest end-to-end check: the app launches under XCUITest and keeps running. It runs against
/// a throwaway data folder (`BREWMENU_DATA_DIR`) and with onboarding already done, so it never
/// touches a user's real BrewMenu data or shows the setup window.
final class LaunchSmokeUITests: XCTestCase {
    func testAppLaunchesAndKeepsRunning() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }

        let app = XCUIApplication(bundleIdentifier: "com.brewmenu.app")
        app.launchEnvironment["BREWMENU_DATA_DIR"] = data.path
        app.launchArguments = ["-hasCompletedOnboarding", "YES"]
        app.launch()

        let running = app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningForeground, timeout: 1)
        XCTAssertTrue(running, "BrewMenu didn't stay running after launch")
        app.terminate()
    }
}
