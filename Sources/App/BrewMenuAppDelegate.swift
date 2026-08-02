import AppKit

/// Handles the app being reopened while already running — double-clicking the .app
/// in Finder/Launchpad/Spotlight, or clicking it in the Dock — which macOS sends to
/// the delegate instead of launching a second process. Reuses the same
/// `.brewMenuOpenSection` notification `BrewMenuNotificationDelegate` posts;
/// `MenuBarIconLabel` (always alive when inserted) opens the Dashboard in response.
@MainActor
final class BrewMenuAppDelegate: NSObject, NSApplicationDelegate {
    /// Wired up by `BrewMenuApp.init()` right after both objects exist. Optional
    /// because `@NSApplicationDelegateAdaptor` constructs this with no arguments —
    /// there's no way to inject it up front.
    var dashboardNav: DashboardNavigation?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // If the icon is currently hidden (nothing to attend to), MenuBarIconLabel
        // doesn't exist yet to catch the notification below — this keeps the status
        // item inserted so SwiftUI remounts it, at which point its own onAppear
        // consumes `forceShowIcon` and opens the Dashboard itself. If the icon is
        // already visible, this is a harmless no-op and the notification below (which
        // its already-live onReceive handles today) does the job as before.
        dashboardNav?.forceShowIcon = true
        NotificationCenter.default.post(name: .brewMenuOpenSection, object: nil, userInfo: ["section": DashboardSection.home])
        return true
    }
}
