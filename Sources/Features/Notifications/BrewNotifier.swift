@preconcurrency import UserNotifications

actor BrewNotifier {
    // UNUserNotificationCenter requires CFBundleIdentifier. When the binary runs without a
    // proper .app bundle (e.g. via swift build or Xcode without Info.plist embedded), calling
    // .current() crashes. Guard here so the rest of the app runs normally without notifications.
    private let center: UNUserNotificationCenter?

    // Per-category enable flags — updated via configure() when settings change.
    private var notifyOnUpdates: Bool = true
    private var notifyOnUpgradeFailure: Bool = true
    private var notifyOnDoctorWarnings: Bool = true
    private var notifyOnCriticalInsights: Bool = true

    // State for update notifications.
    private var lastNotifiedCount = 0
    private var lastNotifiedAt: Date?

    // State for doctor warning notifications.
    private var knownDoctorWarningMessages: Set<String> = []
    private var lastDoctorNotifiedAt: Date?

    // State for critical insight notifications — tracks current critical set so vanished insights
    // are treated as new if they come back.
    private var knownCriticalInsightIDs: Set<String> = []

    init() {
        self.center = Bundle.main.bundleIdentifier != nil ? .current() : nil
    }

    // MARK: - Configuration

    /// Applies the user's notification preferences. Call whenever settings are saved.
    func configure(
        notifyOnUpdates: Bool,
        notifyOnUpgradeFailure: Bool,
        notifyOnDoctorWarnings: Bool,
        notifyOnCriticalInsights: Bool
    ) {
        self.notifyOnUpdates = notifyOnUpdates
        self.notifyOnUpgradeFailure = notifyOnUpgradeFailure
        self.notifyOnDoctorWarnings = notifyOnDoctorWarnings
        self.notifyOnCriticalInsights = notifyOnCriticalInsights
    }

    // MARK: - Authorization

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    // MARK: - Update notifications

    /// Fires a notification when the outdated count increases, with a 1-hour throttle.
    func notifyIfUpdatesIncreased(to newCount: Int) async {
        guard let center, notifyOnUpdates, newCount > 0, newCount > lastNotifiedCount else { return }

        let now = Date()
        if let last = lastNotifiedAt, now.timeIntervalSince(last) < 3600 {
            // Still throttled — track the new count silently so we don't miss the next increase.
            lastNotifiedCount = newCount
            return
        }

        lastNotifiedCount = newCount
        lastNotifiedAt = now

        let content = UNMutableNotificationContent()
        content.title = L("Homebrew Updates Available")
        content.body = newCount == 1
            ? L("1 package needs updating.")
            : L("\(newCount) packages need updating.")
        content.sound = .default
        content.threadIdentifier = "brew.updates"

        let request = UNNotificationRequest(
            identifier: "brew.updates-available",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    // MARK: - Doctor warning notifications

    /// Fires a notification for each doctor run that produces warnings not seen in the previous run.
    /// Uses a 1-hour throttle to avoid flooding when checks run frequently.
    func notifyNewDoctorWarnings(_ warnings: [DoctorWarning]) async {
        guard let center, notifyOnDoctorWarnings else {
            knownDoctorWarningMessages = Set(warnings.map(\.message))
            return
        }

        let currentMessages = Set(warnings.map(\.message))
        let newMessages = currentMessages.subtracting(knownDoctorWarningMessages)
        knownDoctorWarningMessages = currentMessages

        guard !newMessages.isEmpty else { return }

        let now = Date()
        if let last = lastDoctorNotifiedAt, now.timeIntervalSince(last) < 3600 { return }
        lastDoctorNotifiedAt = now

        let content = UNMutableNotificationContent()
        content.title = L("Homebrew Doctor Warning")
        if newMessages.count == 1, let msg = newMessages.first {
            content.body = msg
        } else {
            content.body = L("\(newMessages.count) new warnings from brew doctor.")
        }
        content.sound = .default
        content.threadIdentifier = "brew.doctor"

        let request = UNNotificationRequest(
            identifier: "brew.doctor-warning",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    // MARK: - Critical insight notifications

    /// Fires a notification for each critical insight not present in the previous check.
    /// Tracks the current critical set so an insight that disappears and returns is treated as new.
    func notifyNewCriticalInsights(_ insights: [Insight]) async {
        let currentCritical = insights.filter { $0.severity == .critical }
        let currentIDs = Set(currentCritical.map(\.id))
        let newIDs = currentIDs.subtracting(knownCriticalInsightIDs)
        knownCriticalInsightIDs = currentIDs

        guard let center, notifyOnCriticalInsights, !newIDs.isEmpty else { return }

        for insight in currentCritical where newIDs.contains(insight.id) {
            let content = UNMutableNotificationContent()
            content.title = insight.title
            content.body = insight.detail
            content.sound = .default
            content.threadIdentifier = "brew.insights"

            let request = UNNotificationRequest(
                identifier: "brew.insight-\(insight.id)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    // MARK: - Upgrade notifications

    /// Fires when a user-initiated upgrade fails.
    func notifyUpgradeFailed(reason: String) async {
        guard let center, notifyOnUpgradeFailure else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Homebrew Upgrade Failed")
        content.body = reason
        content.sound = .default
        content.threadIdentifier = "brew.errors"

        let request = UNNotificationRequest(
            identifier: "brew.upgrade-failed",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    /// Resets the tracked count so the next successful check can notify fresh.
    func resetAfterUpgrade() {
        lastNotifiedCount = 0
        lastNotifiedAt = nil
    }
}
