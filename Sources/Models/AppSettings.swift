import Foundation

struct AppSettings: Codable, Sendable, Equatable {
    var checkInterval: CheckInterval = .hourly
    var customBrewPath: String? = nil
    var launchAtLogin: Bool = false
    var notifyOnUpdates: Bool = true
    var notifyOnUpgradeFailure: Bool = true
    var notifyOnDoctorWarnings: Bool = true
    var notifyOnCriticalInsights: Bool = true
    var hasCompletedOnboarding: Bool = false

    // Tolerant decoder: missing keys fall back to defaults so that older settings.json
    // files (which pre-date new fields) decode successfully instead of throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkInterval = try c.decodeIfPresent(CheckInterval.self, forKey: .checkInterval) ?? .hourly
        customBrewPath = try c.decodeIfPresent(String.self, forKey: .customBrewPath)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        notifyOnUpdates = try c.decodeIfPresent(Bool.self, forKey: .notifyOnUpdates) ?? true
        notifyOnUpgradeFailure = try c.decodeIfPresent(Bool.self, forKey: .notifyOnUpgradeFailure) ?? true
        notifyOnDoctorWarnings = try c.decodeIfPresent(Bool.self, forKey: .notifyOnDoctorWarnings) ?? true
        notifyOnCriticalInsights = try c.decodeIfPresent(Bool.self, forKey: .notifyOnCriticalInsights) ?? true
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
    }

    init() {}

    enum CheckInterval: String, Codable, Sendable, CaseIterable {
        case hourly = "hourly"
        case sixHours = "sixHours"
        case daily = "daily"
        case manual = "manual"

        var displayName: String {
            switch self {
            case .hourly:   L("Every hour")
            case .sixHours: L("Every 6 hours")
            case .daily:    L("Daily")
            case .manual:   L("Manual")
            }
        }

        var statusCheckerInterval: StatusChecker.Interval {
            switch self {
            case .hourly: .hourly
            case .sixHours: .sixHours
            case .daily: .daily
            case .manual: .manual
            }
        }
    }
}
