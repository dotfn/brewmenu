import Foundation

func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppBundle.resources)
}
