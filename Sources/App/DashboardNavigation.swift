import BrewCore
import Foundation

@MainActor
@Observable
final class DashboardNavigation {
    var selectedSection: DashboardSection = .home {
        didSet {
            guard selectedSection != oldValue else { return }
            path = pathForNextSection ?? []
            pathForNextSection = nil
        }
    }

    /// What's been opened on top of the section — a collection, a package's page — in the detail
    /// column's `NavigationStack`. Another section starts from its own top.
    var path: [DashboardRoute] = []
    @ObservationIgnored private var pathForNextSection: [DashboardRoute]?

    /// Shows one collection, from anywhere.
    func openCollection(_ pack: InstallPack) {
        if selectedSection == .collections {
            path = [.collection(pack)]
        } else {
            pathForNextSection = [.collection(pack)]
            selectedSection = .collections
        }
    }

    /// Opens a package's page on top of whatever is showing — the App Store's way, instead of a
    /// sheet that blocked the list behind it.
    func openPackage(_ target: PackageDetailTarget) {
        path.append(.package(target))
    }

    /// Set by `BrewMenuAppDelegate` when the app is reopened (Dock/Finder icon) while
    /// the menu bar icon is hidden — keeps it inserted long enough for
    /// `MenuBarIconLabel` to remount and open the Dashboard. Cleared once the
    /// Dashboard window closes (see `DashboardView`'s onDisappear).
    var forceShowIcon: Bool = false
    /// Whether the Dashboard window is currently open — also keeps the menu bar icon
    /// inserted, since it's the only way back to Settings/Quit while it's up.
    var isWindowOpen: Bool = false

    /// Whether the upgrade log sheet is up. Here, not in the Updates page: an upgrade started from
    /// any row in this window (a catalog row's or a package page's Update pill) shows its log too —
    /// those used to run with nothing but a spinner, and fail without a word. An upgrade from the
    /// menu bar doesn't set it, so opening the Dashboard later doesn't pop a sheet.
    var showsUpgradeLog = false

    var shouldForceIconVisible: Bool {
        forceShowIcon || isWindowOpen
    }

    /// Where reopening the app (Dock, Finder) leaves the Dashboard: where it is, if it's open —
    /// sending it back to Discover threw away the section (and page) the user was on.
    var sectionForReopen: DashboardSection {
        isWindowOpen ? selectedSection : .home
    }
}

/// A page pushed onto a section in the Dashboard's detail column.
enum DashboardRoute: Hashable {
    case collection(InstallPack)
    case package(PackageDetailTarget)
}

enum DashboardSection: Hashable {
    case home, apps, commandLine, collections, outdatedPackages, installed
    case ecosystemsOverview // every ecosystem (official + third-party) with an install count — the
    // sidebar's Taps ▸ Overview
    case ecosystem(String) // tap name, e.g. "homebrew/core"
    case thirdPartyEcosystems // groups every non-Homebrew tap together
    case searchResults // full `brew search` results — reached via the sidebar search field
    case services, doctorWarnings, insights, cache, diskUsage
    case settings

    /// The App Store-style top of the sidebar: browse, then what's yours.
    static let mainSections: [DashboardSection] = [
        .home, .apps, .commandLine, .collections, .outdatedPackages, .installed,
    ]
    static let toolSections: [DashboardSection] = [
        .services, .doctorWarnings, .insights, .cache, .diskUsage,
    ]

    var title: String {
        switch self {
        case .home: L("Discover")
        case .apps: L("Apps")
        case .commandLine: L("Command Line")
        case .collections: L("Collections")
        case .installed: L("Installed")
        case .outdatedPackages: L("Updates")
        case .ecosystemsOverview: L("Ecosystems")
        case let .ecosystem(tap): Tap(name: tap).displayName
        case .thirdPartyEcosystems: L("Third-Party")
        case .searchResults: L("Search Results")
        case .services: L("Services")
        case .doctorWarnings: L("Doctor Warnings")
        case .insights: L("Insights")
        case .cache: L("Cache")
        case .diskUsage: L("Disk Usage")
        case .settings: L("Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "star"
        case .apps: "square.grid.2x2"
        case .commandLine: "terminal"
        case .collections: "square.stack"
        case .installed: "checkmark.circle"
        case .outdatedPackages: "arrow.down.app"
        case .ecosystemsOverview: "cube.box.fill"
        case .ecosystem: "cube.box"
        case .thirdPartyEcosystems: "shippingbox.and.arrow.backward"
        case .searchResults: "magnifyingglass"
        case .services: "gearshape.2"
        case .doctorWarnings: "stethoscope"
        case .insights: "lightbulb"
        case .cache: "archivebox"
        case .diskUsage: "internaldrive"
        case .settings: "gearshape"
        }
    }
}
