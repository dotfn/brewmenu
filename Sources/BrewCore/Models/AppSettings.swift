import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var checkInterval: CheckInterval = .hourly
    public var customBrewPath: String?
    public var launchAtLogin: Bool = false
    public var notifyOnUpdates: Bool = true
    public var notifyOnUpgradeFailure: Bool = true
    public var notifyOnDoctorWarnings: Bool = true
    public var notifyOnCriticalInsights: Bool = true
    public var showUpdateBadge: Bool = true
    public var hideMenuBarIconWhenClear: Bool = false

    /// Tolerant decoder: missing keys fall back to defaults so that older settings.json
    /// files (which pre-date new fields) decode successfully instead of throwing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkInterval = try c.decodeIfPresent(CheckInterval.self, forKey: .checkInterval) ?? .hourly
        customBrewPath = try c.decodeIfPresent(String.self, forKey: .customBrewPath)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        notifyOnUpdates = try c.decodeIfPresent(Bool.self, forKey: .notifyOnUpdates) ?? true
        notifyOnUpgradeFailure = try c.decodeIfPresent(Bool.self, forKey: .notifyOnUpgradeFailure) ?? true
        notifyOnDoctorWarnings = try c.decodeIfPresent(Bool.self, forKey: .notifyOnDoctorWarnings) ?? true
        notifyOnCriticalInsights = try c.decodeIfPresent(Bool.self, forKey: .notifyOnCriticalInsights) ?? true
        showUpdateBadge = try c.decodeIfPresent(Bool.self, forKey: .showUpdateBadge) ?? true
        hideMenuBarIconWhenClear = try c.decodeIfPresent(Bool.self, forKey: .hideMenuBarIconWhenClear) ?? false
    }

    public init() {}

    public enum CheckInterval: String, Codable, CaseIterable, Sendable {
        case hourly
        case sixHours
        case daily
        case manual

        public var displayName: String {
            switch self {
            case .hourly: L("Every hour")
            case .sixHours: L("Every 6 hours")
            case .daily: L("Daily")
            case .manual: L("Manual")
            }
        }
    }
}
