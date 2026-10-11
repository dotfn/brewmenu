import AppKit
import BrewCore
import SwiftUI

/// A small pill-shaped status label (e.g. "Outdated") — shared so every browse view
/// (Installed, Ecosystems, Categories, Trending, Recommended, Search) renders it
/// identically instead of each hand-rolling its own badge with its own contrast.
struct StatusBadge: View {
    let text: String
    var color: Color = .outdatedBadge
    /// Yellow fills (`.outdatedIcon`) need dark text, not white — a yellow bright
    /// enough to read as "yellow" is too light for white text to clear WCAG AA no
    /// matter the hue (the same ceiling that keeps `.outdatedBadge` itself at the
    /// darkest orange that still works with white). Black-on-yellow is the standard
    /// warning-label pairing precisely because it sidesteps that ceiling.
    var foregroundColor: Color = .white

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

/// Builds a `Color` from two verified sRGB triples (0-1 components) and resolves
/// between them at draw time from the real system appearance — the AppKit-native
/// way to make a custom color adapt to light/dark, same mechanism `NSColor`'s own
/// semantic colors (`.windowBackgroundColor` etc.) use internally. Needed because
/// none of the three colors below can be a single fixed value: each one is drawn
/// both as a small bare icon glyph (needs the 3:1 WCAG non-text minimum against
/// whatever light-or-dark surface it sits on) and, for `outdatedIcon`, as a
/// `StatusBadge` fill with black text on top (needs 4.5:1) — one shade can't clear
/// both bars in both appearances, so each gets a light-surface-safe and a
/// dark-surface-safe variant, each independently verified below.
private func adaptiveColor(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let (r, g, b) = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    })
}

extension Color {
    /// A darker orange than `.orange` — plain `.orange` text/fill fails WCAG AA
    /// (≈2.1:1 against light or dark backgrounds). White text on this shade measures
    /// ≈4.52:1, just clearing the 4.5:1 minimum for normal-size text.
    static let outdatedBadge = Color(red: 0.75, green: 0.35, blue: 0.0)

    /// Gold/amber, for every "needs attention" context (the menu bar icon, the
    /// popover header icon, warning triangles, and the `StatusBadge` pill — paired
    /// with dark text there, never white, see `StatusBadge.foregroundColor`).
    /// Used to be plain system `.yellow`: that passes fine as a `StatusBadge` fill
    /// (which is why it went unnoticed for so long) but fails the WCAG 3:1 non-text
    /// minimum as a bare icon glyph (measured ≈1.51:1 against a light surface) —
    /// every other call site here uses it exactly that way (`CardStyle`'s
    /// `RestartBanner`, `MenuBarView`'s header/warning rows, `MenuBarIcon`,
    /// `HomeView`'s outdated `StatCard`). Verified both ways instead:
    /// light-surface variant measures ≈4.90:1 for black text and ≈3.68:1 as a bare
    /// icon; dark-surface variant measures ≈8.84:1 / ≈4.42:1.
    static let outdatedIcon = adaptiveColor(light: (0.62, 0.45, 0.0), dark: (0.85, 0.62, 0.05))

    /// Darker goldenrod for "Deprecated" — white text measures ≈5.86:1.
    static let deprecatedBadge = Color(red: 0.51, green: 0.37, blue: 0.0)

    /// Dark red for "Disabled" (more severe than deprecated — disabled formulae/casks
    /// can fail to install) — white text measures ≈8.72:1. Deliberately a separate,
    /// darker red from `.errorIcon` below: this one marks a persistent package
    /// *property* (disabled), `.errorIcon` marks a transient action *failure*
    /// (install/uninstall/upgrade/service error) — same severity tier, different
    /// lifetime, kept visually distinct on purpose.
    static let disabledBadge = Color(red: 0.59, green: 0.08, blue: 0.08)

    /// Green, for every bare "success/ok/installed" icon glyph (service running dot,
    /// install-succeeded checkmarks, the menu bar's `.ok` state). Plain system
    /// `.green` measures only ≈2.22:1 against a light surface as a bare icon —
    /// below the 3:1 minimum, and nowhere close to the 4.5:1 some of these call
    /// sites need since a couple of them color the adjoining text too (e.g.
    /// `OnboardingView`'s "Notifications enabled"). Light-surface variant measures
    /// ≈4.83:1 (clears the text case too); dark-surface variant ≈6.26:1.
    static let successIcon = adaptiveColor(light: (0.03, 0.52, 0.03), dark: (0.25, 0.75, 0.25))

    /// Red, for every bare "error/failed" icon or label (install/uninstall failures,
    /// the menu bar's `.error` state, a service's error dot, insight/doctor-warning
    /// critical rows). Plain system `.red` measures ≈3.55:1 against a light surface
    /// and ≈2.96:1 against a dark one — under the 4.5:1 several of these need
    /// because the color lands on `Label` text, not just the icon (e.g.
    /// `ThirdPartyEcosystemsView`'s inline error labels). Light-surface variant
    /// measures ≈6.40:1; dark-surface variant ≈5.34:1. Not used for destructive
    /// *button* tinting (`role: .destructive`, hover-to-red trash icons) — those
    /// stay plain system `.red`, the platform's own standard for that control role.
    static let errorIcon = adaptiveColor(light: (0.75, 0.05, 0.05), dark: (0.95, 0.45, 0.45))
}

// Every call site above spells these three as `Color.outdatedIcon`/`.successIcon`/
// `.errorIcon` (never the bare leading-dot `.outdatedIcon`) inside a generic
// `some ShapeStyle` parameter (`.foregroundStyle(...)`, `.background(...)`'s style
// argument) — confirmed against this toolchain (Xcode 26 / macOS 27 SDK) that the
// bare leading-dot form silently fails to resolve a same-module `Color` extension
// member in that specific generic-parameter position when the declaration lives in
// another file, while the exact same member resolves fine as the arm of a `switch`
// whose return type is the concrete `Color` (every `tintColor: Color` computed
// property in this codebase), or as a concrete `Color`/`Color?` parameter default
// (`.tint(_:)`, `StatusBadge.color`). Spelling the type out sidesteps it everywhere.

/// The trailing status indicator shared by every "might already be installed"
/// browse row (Trending, Search Results, Available Tap Packages).
struct PackageStatusIndicator: View {
    let name: String
    let isCask: Bool
    @Environment(DashboardViewModel.self) private var dashboardViewModel

    private var isInstalled: Bool {
        dashboardViewModel.isInstalled(name)
    }

    private var isOutdated: Bool {
        dashboardViewModel.isOutdated(name)
    }

    private var failed: Bool {
        dashboardViewModel.failedInstallNames.contains(name)
    }

    var body: some View {
        if isInstalled {
            InstalledStatusButton(name: name, isCask: isCask, isOutdated: isOutdated)
        } else if dashboardViewModel.installingNames.contains(name) {
            ProgressView().controlSize(.small)
                .frame(width: 24, height: 24)
                .accessibilityLabel(L("Installing \(name)"))
        } else {
            let busy = dashboardViewModel.isInstalling
            Button {
                dashboardViewModel.installSingle(name: name, isCask: isCask)
            } label: {
                Image(systemName: failed ? "exclamationmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(failed ? Color.errorIcon : .accentColor)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .disabled(busy)
            .help(busy ? L("Another install is in progress") : (failed ? L("Try Again") : L("Install")))
            .accessibilityLabel(failed ? L("Retry installing \(name)") : L("Install \(name)"))
        }
    }
}

/// The installed-state status icon for browse rows — clicking it uninstalls (with the
/// same confirmation `InstalledPackageRow`'s trash button uses), instead of a dead-end
/// checkmark that gave no way back out of an accidental install without switching to
/// the Installed list. Same look as that trash button too: plain trash icon, red on
/// hover — not a checkmark that swaps to trash, so both rows read the same way.
private struct InstalledStatusButton: View {
    let name: String
    let isCask: Bool
    let isOutdated: Bool
    @Environment(DashboardViewModel.self) private var dashboardViewModel

    @State private var isHovering = false
    @FocusState private var trashFocused: Bool
    @State private var showingUninstallConfirmation = false

    private var failedUninstall: Bool {
        dashboardViewModel.failedUninstallNames.contains(name)
    }

    var body: some View {
        if dashboardViewModel.uninstallingNames.contains(name) {
            ProgressView().controlSize(.small)
                .frame(width: 24, height: 24)
                .accessibilityLabel(L("Uninstalling \(name)"))
        } else {
            Button {
                showingUninstallConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isHovering || trashFocused || failedUninstall ? .red : .secondary)
            .focused($trashFocused)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .help(dashboardViewModel
                .uninstallErrors[name] ??
                (isOutdated ? L("Outdated — click to uninstall") : L("Installed — click to uninstall")))
            .accessibilityLabel(L("Uninstall \(name)"))
            .uninstallConfirmation(
                isPresented: $showingUninstallConfirmation,
                name: name,
                dependents: dashboardViewModel.installedDependents(of: name)
            ) {
                Task { await dashboardViewModel.uninstall(name: name, isCask: isCask) }
            }
        }
    }
}

/// The info-circle button that opens a package's detail sheet — identical everywhere
/// it appears (Installed, Recommended, every browse row via `PackageBrowseRow`), so
/// written once instead of re-typed with each new row type.
struct PackageInfoButton: View {
    let name: String
    let isCask: Bool
    var tap: String?
    @Environment(DashboardViewModel.self) private var dashboardViewModel

    var body: some View {
        Button {
            dashboardViewModel.selectPackage(name: name, isCask: isCask, tap: tap)
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .frame(minWidth: 24, minHeight: 24)
        .contentShape(Rectangle())
        .help(L("Package info"))
        .accessibilityLabel(L("Package info for \(name)"))
    }
}

/// The row shape shared by every "browse to install" list — icon, monospaced name,
/// an optional bit of leading/trailing content specific to that list (a warning
/// triangle, an install count, a status pill…), an info button, then the status
/// indicator. Trending, Search Results, and Available Tap Packages are the exact
/// same row wearing different trailing content — this is that row, written once.
struct PackageBrowseRow<Trailing: View>: View {
    let name: String
    let isCask: Bool
    var tap: String?
    var accessibilityLabel: String?
    let trailing: Trailing

    init(
        name: String,
        isCask: Bool,
        tap: String? = nil,
        accessibilityLabel: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.name = name
        self.isCask = isCask
        self.tap = tap
        self.accessibilityLabel = accessibilityLabel
        self.trailing = trailing()
    }

    /// Narrower than a variable-width text pill needed, now that this column holds a
    /// fixed 24pt icon.
    @ScaledMetric(relativeTo: .caption) private var statusColumnWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isCask ? "app.badge" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(verbatim: name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 12)
                trailing
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel ?? name)

            PackageInfoButton(name: name, isCask: isCask, tap: tap)

            PackageStatusIndicator(name: name, isCask: isCask)
                .frame(width: statusColumnWidth, alignment: .trailing)
        }
    }
}

extension PackageBrowseRow where Trailing == EmptyView {
    /// A row with no trailing content — the plain "browse to install" shape.
    init(name: String, isCask: Bool, tap: String? = nil, accessibilityLabel: String? = nil) {
        self.init(name: name, isCask: isCask, tap: tap, accessibilityLabel: accessibilityLabel) { EmptyView() }
    }
}
