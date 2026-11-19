import AppKit
import BrewCore
import notify

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
    private var askpassToken: Int32 = 0

    func applicationDidFinishLaunching(_: Notification) {
        // The admin-password dialog belongs to another process, and closing it leaves focus
        // wherever macOS puts it. Only a Dashboard that was already open gets it back — an
        // operation started from the menu bar mustn't open a window.
        // Registered for the app's lifetime, so the token is never cancelled.
        let status = notify_register_dispatch(BrewService.askpassFinishedNotification, &askpassToken, .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.dashboardNav?.isWindowOpen == true else { return }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        if status != NOTIFY_STATUS_OK {
            Task {
                await BrewLogger.shared.log("AppDelegate: can't observe the askpass dialog (notify \(status))", .warn)
            }
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // If the icon is currently hidden (nothing to attend to), MenuBarIconLabel
        // doesn't exist yet to catch the notification below — this keeps the status
        // item inserted so SwiftUI remounts it, at which point its own onAppear
        // consumes `forceShowIcon` and opens the Dashboard itself. If the icon is
        // already visible, this is a harmless no-op and the notification below (which
        // its already-live onReceive handles today) does the job as before.
        dashboardNav?.forceShowIcon = true
        NotificationCenter.default.post(
            name: .brewMenuOpenSection,
            object: nil,
            userInfo: ["section": dashboardNav?.sectionForReopen ?? DashboardSection.home]
        )
        return true
    }

    /// AppKit's default (undeclared) behavior is `true` — closing the Dashboard
    /// window, an accessory/menu-bar-only app's only *regular* window, would quit the
    /// whole app, taking the menu bar item down with it. The popover (`MenuBarExtra`)
    /// isn't a real window for this check, so without this override there'd be no way
    /// back in except relaunching from Finder/Spotlight.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
