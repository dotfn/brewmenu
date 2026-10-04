import Foundation

/// Stable accessibility identifiers for the controls a UI harness needs to find. Identifiers are
/// not localised and must not change with copy, so tests can rely on them.
enum AccessibilityID {
    static let upgradeAllButton = "upgradeAll.button"
    static let upgradeSheetPrimary = "upgradeSheet.primary"
    static let upgradeSheetCopyError = "upgradeSheet.copyError"
    static let upgradeSheetRetry = "upgradeSheet.retry"
    static let packageUpgradeButton = "package.upgrade"
}
