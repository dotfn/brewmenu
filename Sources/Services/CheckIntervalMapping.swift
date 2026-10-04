import BrewCore
import Foundation

extension AppSettings.CheckInterval {
    /// How the background checker runs for this setting. Lives with the checker, not in the model,
    /// so the settings model doesn't depend on the service layer.
    var statusCheckerInterval: StatusChecker.Interval {
        switch self {
        case .hourly: .hourly
        case .sixHours: .sixHours
        case .daily: .daily
        case .manual: .manual
        }
    }
}
