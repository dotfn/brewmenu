import AppKit
import BrewCore
import SwiftUI

// The App Store-style building blocks the catalog screens share: a package's icon, its action
// pill, the row that puts them together, section headers and collection tiles.

// MARK: - Icon

/// The real icon for an app that's on disk, a monogram for everything else. Homebrew's data has no
/// icons, and fetching one from each project's site would mean a request to every one of them.
struct PackageIcon: View {
    let name: String
    let displayName: String
    let isCask: Bool
    var appPath: String?
    var size: CGFloat = 40
    @Environment(DashboardViewModel.self) private var dashboardViewModel

    @State private var appIcon: CGImage?

    /// Rechecked when the package gets installed or removed, so a fresh install shows its icon.
    private struct IconKey: Equatable {
        let appPath: String?
        let isInstalled: Bool
    }

    var body: some View {
        Group {
            if let appIcon {
                Image(decorative: appIcon, scale: 2)
                    .resizable()
                    .interpolation(.high)
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .task(id: IconKey(appPath: appPath, isInstalled: dashboardViewModel.isInstalled(name))) {
            guard let appPath else { return appIcon = nil }
            appIcon = await AppIconCache.icon(at: appPath, points: size)
        }
        .accessibilityHidden(true)
    }

    /// Drawn on the same grid as a macOS app icon: the shape is 824 of 1024 points, centered, with
    /// a soft shadow in the margin. Filling the whole frame made monograms look a size bigger than
    /// the real app icons next to them.
    private var monogram: some View {
        let hue = Self.hue(for: name)
        let body = size * Self.iconBodyRatio
        return RoundedRectangle(cornerRadius: body * 0.225, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                         Color(hue: hue, saturation: 0.7, brightness: 0.6)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay {
                Text(verbatim: initials)
                    .font(.system(size: body * 0.45, weight: .semibold, design: isCask ? .rounded : .monospaced))
                    .foregroundStyle(.white)
            }
            .frame(width: body, height: body)
            .shadow(color: .black.opacity(0.25), radius: size * 0.012, y: size * 0.01)
    }

    /// The macOS icon grid's shape size over its canvas (824 / 1024).
    private static let iconBodyRatio: CGFloat = 824 / 1024

    /// Apps get the first letter of their name; command-line tools a shell-prompt look, so the two
    /// kinds tell apart at a glance.
    private var initials: String {
        let letter = displayName.first(where: \.isLetter).map { String($0).uppercased() } ?? "?"
        return isCask ? letter : ">\(letter.lowercased())"
    }

    /// Stable across launches (unlike `hashValue`), so a package keeps its color.
    private static func hue(for name: String) -> Double {
        let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return Double(hash % 360) / 360
    }
}

/// App icons by path, read off the main actor (it's disk work) and kept once found. Misses aren't
/// kept: an app that isn't there yet may be installed a minute later. `NSCache` is thread-safe,
/// and the images are `CGImage`s, which can cross actors — `NSImage` can't.
enum AppIconCache {
    private nonisolated(unsafe) static let cache = NSCache<NSString, CGImage>()

    @concurrent
    static func icon(at path: String, points: CGFloat) async -> CGImage? {
        let key = "\(path)@\(Int(points))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: points * 2, height: points * 2)
        guard let image = NSWorkspace.shared.icon(forFile: path)
            .cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Whether the app is on disk, off the main actor.
    @concurrent
    static func exists(at path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

// MARK: - Action pill

/// The capsule on the right of every row — Get, Update, Open or Installed, depending on the state
/// of the package — like the App Store's. Uninstalling sits in the installed pill's menu.
struct StoreActionButton: View {
    let name: String
    let isCask: Bool
    var appPath: String?
    /// Homebrew refuses to install a disabled package, so there's no Get to offer.
    var isDisabledUpstream = false
    @Environment(DashboardViewModel.self) private var dashboardViewModel
    @Environment(MenuBarViewModel.self) private var menuBarViewModel
    @Environment(DashboardNavigation.self) private var navigation
    @State private var showingUninstallConfirmation = false
    /// Filled in when Uninstall is chosen, not on every render: it scans every installed package.
    @State private var dependents: [String] = []
    /// Whether the app is on disk, checked off the main actor (see `.task` below).
    @State private var appIsOnDisk = false

    @ScaledMetric(relativeTo: .body) private var pillWidth: CGFloat = 78

    private var isInstalled: Bool {
        dashboardViewModel.isInstalled(name)
    }

    private var isBusy: Bool {
        dashboardViewModel.installingNames.contains(name)
            || dashboardViewModel.uninstallingNames.contains(name)
            || menuBarViewModel.upgradingPackages.contains(name)
    }

    /// The app's location once it's actually there — an installed cask can put it somewhere else.
    private var openableApp: URL? {
        guard isCask, isInstalled, appIsOnDisk, let appPath else { return nil }
        return URL(fileURLWithPath: appPath)
    }

    private func confirmUninstall() {
        dependents = dashboardViewModel.installedDependents(of: name)
        showingUninstallConfirmation = true
    }

    var body: some View {
        Group {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L("Working on \(name)"))
            } else if isInstalled {
                installedMenu
            } else {
                getButton
            }
        }
        .frame(minWidth: pillWidth)
        .task(id: isInstalled) {
            appIsOnDisk = if isInstalled, let appPath { await AppIconCache.exists(at: appPath) } else { false }
        }
        .uninstallConfirmation(
            isPresented: $showingUninstallConfirmation,
            name: name,
            dependents: dependents
        ) {
            Task { await dashboardViewModel.uninstall(name: name, isCask: isCask) }
        }
    }

    private var getButton: some View {
        let failed = dashboardViewModel.installErrors[name] != nil
        return Button {
            dashboardViewModel.installSingle(name: name, isCask: isCask)
        } label: {
            Text(failed ? L("Retry") : L("Get"))
                .fontWeight(.semibold)
                .frame(minWidth: pillWidth - 24)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(failed ? .red : .accentColor)
        .disabled(dashboardViewModel.isInstalling || isDisabledUpstream)
        .help(isDisabledUpstream
            ? L("Homebrew has disabled this package, so it can't be installed.")
            : dashboardViewModel.isInstalling
            ? L("Another install is in progress")
            : dashboardViewModel.installErrors[name] ?? L("Install"))
        .accessibilityLabel(failed ? L("Retry installing \(name)") : L("Install \(name)"))
    }

    /// Update when there's one, Open for an app, Installed otherwise — with Uninstall behind it.
    private var installedMenu: some View {
        let isOutdated = dashboardViewModel.isOutdated(name)
        let title = isOutdated ? L("Update") : openableApp != nil ? L("Open") : L("Installed")
        return Menu {
            if isOutdated, let openableApp {
                Button(L("Open")) { open(openableApp) }
            }
            Button(L("Uninstall…"), role: .destructive) { confirmUninstall() }
        } label: {
            Text(title).fontWeight(.semibold)
        } primaryAction: {
            if isOutdated {
                // Its log, like the Updates page's — for a run that really started.
                if menuBarViewModel.upgradePackage(name) { navigation.showsUpgradeLog = true }
            } else if let openableApp {
                open(openableApp)
            } else {
                confirmUninstall()
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(isOutdated ? .accentColor : .secondary)
        .fixedSize()
        .disabled(isOutdated && menuBarViewModel.isRunningAnyUpgrade)
        .help(dashboardViewModel.uninstallErrors[name] ?? (isOutdated ? L("Update \(name)") : title))
        .accessibilityLabel(isOutdated ? L("Update \(name)") : L("\(name), installed"))
    }

    private func open(_ app: URL) {
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Row

/// One package in a catalog list: icon, name, one-line description, action pill. Clicking the row
/// opens the package's detail.
struct StorePackageRow: View {
    let package: CatalogPackage
    var iconSize: CGFloat = 40
    @Environment(DashboardNavigation.self) private var navigation

    var body: some View {
        HStack(spacing: 12) {
            Button {
                navigation.openPackage(PackageDetailTarget(
                    name: package.name,
                    isCask: package.isCask,
                    tap: package.tap
                ))
            } label: {
                HStack(spacing: 12) {
                    PackageIcon(
                        name: package.name,
                        displayName: package.displayName,
                        isCask: package.isCask,
                        appPath: package.appPath,
                        size: iconSize
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: package.displayName)
                                .font(.headline)
                                .lineLimit(1)
                            if package.disabled {
                                StatusBadge(text: L("Disabled"), color: .disabledBadge)
                            } else if package.deprecated {
                                StatusBadge(text: L("Deprecated"), color: .deprecatedBadge)
                            }
                        }
                        Text(verbatim: package.desc ?? package.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(L("Shows details"))

            StoreActionButton(
                name: package.name,
                isCask: package.isCask,
                appPath: package.appPath,
                isDisabledUpstream: package.disabled
            )
        }
        .padding(.vertical, 6)
    }

    private var accessibilityLabel: String {
        var parts = [package.displayName]
        if let desc = package.desc { parts.append(desc) }
        if package.disabled { parts.append(L("disabled")) } else if package.deprecated { parts.append(L("deprecated")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Section header

/// A large section title with an optional "See All", like the App Store's.
struct StoreSectionHeader: View {
    let title: String
    var seeAll: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let seeAll {
                Button(L("See All"), action: seeAll)
                    .buttonStyle(.link)
                    .font(.title3)
            }
        }
    }
}

// MARK: - Collection tile

/// One collection in the grid: its symbol in color and its name, over a hairline — the App Store's
/// category grid.
struct CollectionTile: View {
    let pack: InstallPack
    var showsDivider = true

    /// The App Store's category glyphs are large and filled; these match their size.
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title2) private var iconColumn: CGFloat = 48

    private var tint: Color {
        Self.tint(for: pack.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: pack.systemImage)
                    .symbolVariant(.fill)
                    // Two shades of the collection's color, both opaque. Multicolor left some
                    // symbols near-black (the terminal) on a dark window, and hierarchical dimmed
                    // the large shapes (the shield, the compass) behind their glyphs.
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(tint, tint.mix(with: .white, by: 0.45))
                    .font(.system(size: iconSize))
                    .frame(width: iconColumn, height: iconColumn)
                Text(pack.localizedTitle)
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            Divider()
                .padding(.leading, iconColumn + 18)
                .opacity(showsDivider ? 1 : 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pack.localizedTitle)
        .accessibilityHint(pack.localizedSubtitle)
    }

    private static let palette: [Color] = [
        .blue, .orange, .green, .pink, .purple, .teal, .red, .indigo, .mint, .yellow, .cyan, .brown,
    ]

    /// A fixed color per collection, so each one is recognizable the way App Store categories are.
    static func tint(for id: String) -> Color {
        let hash = id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[hash % palette.count]
    }
}

/// The catalog entry for a pack member, or a minimal stand-in for one the catalog doesn't have
/// (a third-party tap's, like `hashicorp/tap/terraform`).
@MainActor
func catalogEntry(_ name: String, isCask: Bool, in store: BrewStore) -> CatalogPackage {
    store.catalogPackage(named: name, isCask: isCask)
        ?? CatalogPackage(
            name: name,
            displayName: String(name.split(separator: "/").last ?? Substring(name)),
            desc: nil,
            version: "",
            isCask: isCask,
            tap: name.split(separator: "/").count == 3 ? name.split(separator: "/").prefix(2)
                .joined(separator: "/") : nil
        )
}
