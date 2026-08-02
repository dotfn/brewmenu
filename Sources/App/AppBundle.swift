import Foundation

/// Resolves the app's SPM resource bundle (localization strings, `InstallPacks.json`, etc).
///
/// `Bundle.module` (SPM-generated) resolves to `Bundle.main.bundleURL/BrewMenu_BrewMenu.bundle`,
/// which is the .app package root — a location codesign rejects as "unsealed contents". This
/// resolver checks Contents/Resources/ first (correct for .app distributions) and falls back to
/// `Bundle.main.bundleURL` (correct for `swift build`/`swift run` dev builds).
enum AppBundle {
    static let resources: Bundle = {
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
}
