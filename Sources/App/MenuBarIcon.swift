import AppKit
import BrewCore
import SwiftUI

/// The MenuBarExtra label.
///
/// `MenuBarExtra` can only show an icon *or* a title text, never both as
/// separate views — confirmed by two failed attempts (a `Label` drops the
/// title; a `Text` with an embedded symbol glyph drops the glyph) and by
/// Apple Developer Forums threads 738716 / 725960. The workaround is to
/// never hand it two views at all: `ImageRenderer` flattens the icon + count
/// into a single bitmap first, so as far as MenuBarExtra is concerned this
/// label is just one plain `Image` — the one combination it reliably renders.
struct MenuBarIconLabel: View {
    let status: MenuBarStatus
    let showBadge: Bool
    let dashboardNav: DashboardNavigation
    var lastChecked: Date?
    @Environment(\.openWindow) private var openWindow

    /// "Last checked 5 minutes ago" for the hover tooltip — so the count in the bar has a
    /// visible age, not just a number. Relative and localized by the system formatter.
    static func checkedTooltip(lastChecked: Date?, now: Date = .now) -> String {
        guard let lastChecked else { return L("Not checked yet") }
        let relative = RelativeDateTimeFormatter().localizedString(for: lastChecked, relativeTo: now)
        return L("Last checked \(relative)")
    }

    var body: some View {
        Image(nsImage: renderedIcon)
            .help(Self.checkedTooltip(lastChecked: lastChecked))
            .accessibilityLabel(status.accessibilityLabel)
            // The label is rendered at launch (it's the status item's own icon), unlike
            // MenuBarView's content — which SwiftUI only builds the first time the popover
            // is opened. This is the one place guaranteed alive early enough to catch a
            // reopen (app icon clicked while already running) or a tapped notification
            // before the user has ever opened the popover.
            .onReceive(NotificationCenter.default.publisher(for: .brewMenuOpenSection)) { note in
                guard let section = note.userInfo?["section"] as? DashboardSection else { return }
                dashboardNav.selectedSection = section
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dashboard")
            }
            // Catches the case where the icon was hidden (nothing to attend to) when
            // the app was reopened — the reopen notification above had nobody to
            // observe it yet, since this view didn't exist until `forceShowIcon`
            // re-inserted it. `forceShowIcon` itself isn't cleared here (it stays true
            // until the Dashboard closes) so the icon doesn't disappear again mid-open.
            .onAppear {
                guard dashboardNav.forceShowIcon else { return }
                dashboardNav.selectedSection = .home
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "dashboard")
            }
    }

    private var badgeCount: Int? {
        guard case let .updates(count) = status, count > 0, showBadge else { return nil }
        return count
    }

    private var renderedIcon: NSImage {
        let composite = HStack(spacing: 3) {
            if let badgeCount {
                Text(verbatim: "\(badgeCount)")
                    .font(.system(size: 12, weight: .semibold))
            }
            Image(systemName: status.menuBarSymbol)
                .font(.system(size: 13, weight: .regular))
        }
        .foregroundStyle(status.menuBarColor)
        .fixedSize()

        let renderer = ImageRenderer(content: composite)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        // .nsImage (not a hand-rolled NSImage(cgImage:size:) from .cgImage) is what
        // preserves the view's wide-gamut (Display P3) colors — reconstructing from
        // the raw CGImage drops the color profile and colors render duller/shifted.
        guard let image = renderer.nsImage else {
            return NSImage(systemSymbolName: status.menuBarSymbol, accessibilityDescription: nil) ?? NSImage()
        }
        // Deliberately not a template image: a template discards hue entirely (the
        // system refills it as flat black/white per appearance), which would lose
        // the ok/warning/error color coding this is the one purpose of. The
        // trade-off is that contrast here isn't auto-guaranteed by the system like
        // a template's would be — `menuBarColor` below carries its own verified
        // light/dark-safe pair per status instead (see `Color.successIcon`'s doc
        // comment), the same mechanism, applied here instead of left to the OS.
        image.isTemplate = false
        return image
    }
}

// MARK: - MenuBarStatus presentation (menu bar icon)

private extension MenuBarStatus {
    /// A brighter, more saturated green than `Color.successIcon` (`StatusBadge.swift`) —
    /// deliberately a separate value, not shared. `successIcon` is held back by also
    /// needing to clear 4.5:1 for the few places it colors adjoining text; this icon
    /// has no adjoining text, so it only needs the 3:1 WCAG non-text floor, leaving
    /// real room for a punchier shade without failing contrast the way plain system
    /// `.green` does (≈2.22:1 against a light surface, confirmed below the minimum).
    /// Light-surface variant measures ≈3.72:1; dark-surface variant ≈11.36:1.
    private static let vibrantOk = adaptiveColor(light: (0.10, 0.60, 0.20), dark: (0.30, 0.85, 0.35))

    var menuBarSymbol: String {
        switch self {
        case .initializing: "hourglass"
        case .ok: "mug.fill"
        case .updates: "mug.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var menuBarColor: Color {
        switch self {
        // Not SwiftUI's `.secondary` — that's a hierarchical style that resolves
        // relative to the surrounding view hierarchy, and this icon has none: it's
        // flattened by `ImageRenderer` into a standalone bitmap with nothing to be
        // "secondary" to, so it fell back to plain black instead of gray (confirmed
        // against a real screenshot — the launch-time hourglass rendered solid
        // black). `.secondaryLabelColor` is AppKit's own dynamic gray, the same fix
        // `Color.brewWindowBackground` already uses for the same class of problem.
        case .initializing: Color(nsColor: .secondaryLabelColor)
        case .ok: Self.vibrantOk
        // Same shade everywhere "updates available" shows up as an icon/glyph (the
        // popover header icon, Insight.Severity.warning, DoctorWarningRow) — not
        // `.outdatedBadge`, which is reserved for text-on-fill badges (StatusBadge)
        // where the brighter `outdatedIcon` would fail white-text contrast. See
        // `outdatedIcon`'s doc comment for why these two shades now differ.
        case .updates: .outdatedIcon
        case .warning: .outdatedIcon
        case .error: .errorIcon
        }
    }

    /// Spoken by VoiceOver for the menu bar status item, which is the app's
    /// sole entry point (it runs as an LSUIElement with no Dock icon).
    var accessibilityLabel: String {
        switch self {
        case .initializing: L("BrewMenu: checking for updates")
        case .ok: L("BrewMenu: all packages up to date")
        case let .updates(count): L("BrewMenu: \(count) upgrades available")
        case let .warning(count): L("BrewMenu: \(count) doctor warnings")
        case .error: L("BrewMenu: error, click for details")
        }
    }
}
