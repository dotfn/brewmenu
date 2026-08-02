import Foundation

@MainActor
@Observable
final class DashboardNavigation {
    var selectedSection: DashboardSection = .home
}

enum DashboardSection: Hashable {
    case home, installed, outdatedPackages, installPacks, recommendedTaps
    case ecosystemsOverview  // every ecosystem (official + third-party) with an install count — reached via Home's "Active ecosystems" stat, not a permanent sidebar row
    case ecosystem(String)   // tap name, e.g. "homebrew/core"
    case thirdPartyEcosystems  // groups every non-Homebrew tap together
    case category(PackageCategory)
    case searchResults        // full `brew search` results — reached via the sidebar search field
    case services, doctorWarnings, insights
    case general, notifications, about

    static let mainSections: [DashboardSection] = [
        .home, .installed, .outdatedPackages, .installPacks, .recommendedTaps,
    ]
    static let toolSections: [DashboardSection] = [
        .services, .doctorWarnings, .insights,
    ]
    static let settingsSections: [DashboardSection] = [.general, .notifications, .about]

    var title: String {
        switch self {
        case .home: L("Home")
        case .installed: L("Installed")
        case .outdatedPackages: L("Outdated Packages")
        case .installPacks: L("Install Packs")
        case .recommendedTaps: L("Recommended Taps")
        case .ecosystemsOverview: L("Ecosystems")
        case .ecosystem(let tap): Tap(name: tap).displayName
        case .thirdPartyEcosystems: L("Third-Party")
        case .category(let category): category.title
        case .searchResults: L("Search Results")
        case .services: L("Services")
        case .doctorWarnings: L("Doctor Warnings")
        case .insights: L("Insights")
        case .general: L("General")
        case .notifications: L("Notifications")
        case .about: L("About")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .installed: "square.grid.2x2"
        case .outdatedPackages: "arrow.up.circle"
        case .installPacks: "shippingbox"
        case .recommendedTaps: "checkmark.seal"
        case .ecosystemsOverview: "cube.box.fill"
        case .ecosystem: "cube.box"
        case .thirdPartyEcosystems: "shippingbox.and.arrow.backward"
        case .category(let category): category.systemImage
        case .searchResults: "magnifyingglass"
        case .services: "gearshape.2"
        case .doctorWarnings: "stethoscope"
        case .insights: "lightbulb"
        case .general: "gearshape"
        case .notifications: "bell"
        case .about: "info.circle"
        }
    }
}
