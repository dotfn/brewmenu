import XCTest

/// User flows through the real UI, against a fake `brew`. Nothing here can upgrade a real package:
/// the fake records an upgrade in a marker file, and the tests check that file.
final class UpgradeFlowUITests: XCTestCase {
    private var env: UITestEnvironment!

    override func setUpWithError() throws {
        continueAfterFailure = false
        env = try UITestEnvironment.make()
    }

    override func tearDownWithError() throws {
        env?.cleanUp()
    }

    /// Opens the popover from the menu bar and waits for the outdated list to load.
    private func openPopover(_ app: XCUIApplication) {
        let item = app.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the menu bar item never appeared")
        // Click the item's centre, not the element: on this macOS the status item is reported as not
        // hittable, so an element click never reaches it, while a coordinate click opens the popover.
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    func testPopoverListsTheOutdatedPackage() {
        let app = env.launchApp()
        defer { app.terminate() }
        openPopover(app)

        // The fake brew reports exactly one outdated package. Seeing it proves the app used the fake,
        // not the machine's real Homebrew.
        let wget = app.buttons["Upgrade wget"]
        XCTAssertTrue(wget.waitForExistence(timeout: 15), "the fake brew's wget row never showed up")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: env.upgradeMarker.path),
            "nothing should have been upgraded yet"
        )
    }

    /// Upgrade All must ask first, and Cancel must leave Homebrew alone.
    func testUpgradeAllAsksAndCancelDoesNotUpgrade() {
        let app = env.launchApp()
        defer { app.terminate() }
        openPopover(app)

        // The label carries the shortcut ("Open Dashboard…, ⌘D"), so match the prefix.
        let openDashboard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Open Dashboard"))
            .firstMatch
        XCTAssertTrue(
            openDashboard.waitForExistence(timeout: 10),
            "the popover's Open Dashboard button never showed up"
        )
        openDashboard.click()

        // The popover has its own "Outdated Packages" label, so scope the lookup to the Dashboard window.
        // Identified by its scene id: the window's title follows the section, so it reads "Home" here.
        let dashboard = app.windows["dashboard"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 10), "the Dashboard window never opened")
        let outdated = dashboard.staticTexts["Outdated Packages"].firstMatch
        XCTAssertTrue(outdated.waitForExistence(timeout: 10), "the sidebar's Outdated Packages item never showed up")
        outdated.click()

        let upgradeAll = dashboard.buttons["upgradeAll.button"]
        XCTAssertTrue(upgradeAll.waitForExistence(timeout: 10), "the Upgrade All button never showed up")
        upgradeAll.click()

        let cancel = dashboard.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the confirmation dialog never appeared")
        cancel.click()

        // An upgrade would start asynchronously, so a missing marker only means something after a
        // short wait. Without it, a Cancel that did run the upgrade could still pass this check.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: env.upgradeMarker.path),
            "Cancel must not run the upgrade"
        )
    }
}
