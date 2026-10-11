import XCTest

/// Screenshot-based visual checks against the real, rendered app — not a mock, not SwiftUI
/// previews. Attachments are `.keepAlways` so they land in the `.xcresult` bundle whether the
/// assertion passes or fails, and can be pulled out with `xcresulttool` for a human (or an
/// agent with no live screen access) to actually look at.
final class VisualRegressionUITests: XCTestCase {
    private var env: UITestEnvironment!

    override func setUpWithError() throws {
        continueAfterFailure = false
        env = try UITestEnvironment.make()
    }

    override func tearDownWithError() throws {
        env?.cleanUp()
    }

    /// The whole physical screen, not scoped to any one app's window — a `MenuBarExtra(.window)`
    /// popover isn't reliably indexed under `XCUIApplication.windows` (confirmed: querying it
    /// right after the content loaded threw "cannot request screenshot data because it does not
    /// exist" even though an element inside it had just matched), so this is the one capture
    /// method that reliably works here.
    private func attachFullScreenScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The menu bar popover, fully loaded (fake brew reports one outdated package and a doctor
    /// warning, matching the state in the screenshots this test exists to check against).
    /// Screenshots unconditionally, even if the expected content never shows up — a failure
    /// screenshot is still the evidence that matters when there's no live screen to look at.
    func testPopoverAppearance() {
        let app = env.launchApp()
        defer { app.terminate() }

        let item = app.statusItems.firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the menu bar item never appeared")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        // Give the popover time to open and settle regardless of what shows up inside it.
        Thread.sleep(forTimeInterval: 2)
        // `click()` opens the popover but doesn't reliably raise it to the front of the
        // physical screen's window stack (confirmed: existence checks against its
        // contents kept passing while a full-screen capture still showed whatever
        // other app happened to be frontmost) — force it forward before each capture.
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        attachFullScreenScreenshot("Full screen after status item click")

        let wget = app.buttons["Upgrade wget"]
        let appeared = wget.waitForExistence(timeout: 15)
        if appeared {
            Thread.sleep(forTimeInterval: 1)
        }
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        attachFullScreenScreenshot("Full screen, final state")
        XCTAssertTrue(appeared, "the fake brew's wget row never showed up")
    }
}
