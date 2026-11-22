import Foundation

public func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppBundle.resources)
}

/// The language the interface is showing — `L`'s, from the strings the app ships — for numbers
/// shown next to its text. `Locale.current` is the Mac's region, which can differ: an English
/// interface on a Spanish Mac read "45 %" beside "Downloading…".
public let interfaceLocale = Locale(identifier: AppBundle.resources.preferredLocalizations.first ?? "en")

public extension BinaryFloatingPoint {
    /// "46%", in the interface's language (see `interfaceLocale`).
    var percentText: String {
        Double(self).formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale))
    }
}
