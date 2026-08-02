import Foundation
@preconcurrency import UserNotifications

extension Notification.Name {
    /// Posted when the user taps a notification — carries the `DashboardSection`
    /// to jump to in its `userInfo["section"]`. `MenuBarIconLabel` (always alive —
    /// it's the status item's own icon, unlike `MenuBarView`'s content which SwiftUI
    /// only builds once the popover is first opened) observes this and opens the
    /// Dashboard window there.
    static let brewMenuOpenSection = Notification.Name("brewMenuOpenSection")
}

/// Routes a tapped notification to the Dashboard section it's about — without this,
/// every notification BrewNotifier sends (updates available, doctor warnings, critical
/// insights, upgrade failures) was a dead end: tapping it did nothing beyond dismissing it.
final class BrewMenuNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let section = Self.section(forThreadIdentifier: response.notification.request.content.threadIdentifier) {
            NotificationCenter.default.post(name: .brewMenuOpenSection, object: nil, userInfo: ["section": section])
        }
        completionHandler()
    }

    private static func section(forThreadIdentifier threadIdentifier: String) -> DashboardSection? {
        switch threadIdentifier {
        case "brew.updates": .outdatedPackages
        case "brew.doctor": .doctorWarnings
        case "brew.insights": .insights
        case "brew.errors": .outdatedPackages
        default: nil
        }
    }
}
