import Foundation

/// Looks up a localized string from the app's resource bundle.
/// Using Bundle.module instead of Bundle.main because SPM packages
/// embed resources in a sub-bundle (BrewMenu_BrewMenu.bundle), not in
/// the main bundle's root.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
