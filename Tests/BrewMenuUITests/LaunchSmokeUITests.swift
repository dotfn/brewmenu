import XCTest

/// The smallest end-to-end check: the app launches under XCUITest and keeps running. It uses the same
/// isolated environment as any future flow test: a throwaway data folder, the fake brew, and
/// onboarding already done.
final class LaunchSmokeUITests: XCTestCase {
    private var env: UITestEnvironment!

    override func setUpWithError() throws {
        env = try UITestEnvironment.make()
    }

    override func tearDownWithError() throws {
        env?.cleanUp()
    }

    func testAppLaunchesAndKeepsRunning() {
        let app = env.launchApp()
        defer { app.terminate() }
        let running = app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningForeground, timeout: 1)
        XCTAssertTrue(running, "BrewMenu didn't stay running after launch")
    }
}
