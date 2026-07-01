import Foundation

/// Looks up a localized string from the app's resource bundle.
///
/// Bundle.module (SPM-generated) resolves to Bundle.main.bundleURL/BrewMenu_BrewMenu.bundle,
/// which is the .app package root — a location codesign rejects as "unsealed contents".
/// This resolver checks Contents/Resources/ first (correct for .app distributions) and
/// falls back to Bundle.main.bundleURL (correct for `swift build` dev runs).
private let _localizations: Bundle = {
    let name = "BrewMenu_BrewMenu.bundle"
    let candidates: [URL?] = [
        Bundle.main.resourceURL?.appendingPathComponent(name),
        Bundle.main.bundleURL.appendingPathComponent(name),
    ]
    for case let url? in candidates {
        if let bundle = Bundle(url: url) { return bundle }
    }
    return Bundle.main
}()

func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: _localizations)
}
