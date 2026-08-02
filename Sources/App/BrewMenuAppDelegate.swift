import AppKit

/// Handles the app being reopened while already running — double-clicking the .app
/// in Finder/Launchpad/Spotlight, or clicking it in the Dock — which macOS sends to
/// the delegate instead of launching a second process. Reuses the same
/// `.brewMenuOpenSection` notification `BrewMenuNotificationDelegate` posts;
/// `MenuBarIconLabel` (always alive) opens the Dashboard in response.
final class BrewMenuAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .brewMenuOpenSection, object: nil, userInfo: ["section": DashboardSection.home])
        return true
    }
}
