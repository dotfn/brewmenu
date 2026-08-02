import AppKit
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: renderedIcon)
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
        guard case .updates(let count) = status, count > 0, showBadge else { return nil }
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
        image.isTemplate = false
        return image
    }
}

// MARK: - MenuBarStatus presentation (menu bar icon)

private extension MenuBarStatus {
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
        case .initializing: .secondary
        case .ok: .green
        // Orange everywhere "updates available" shows up (Home's StatCard, the
        // Outdated StatusBadge, Insight.Severity.warning) — this used to be yellow,
        // the only place in the app where that state wasn't orange.
        case .updates: .orange
        case .warning: .orange
        case .error: .red
        }
    }

    /// Spoken by VoiceOver for the menu bar status item, which is the app's
    /// sole entry point (it runs as an LSUIElement with no Dock icon).
    var accessibilityLabel: String {
        switch self {
        case .initializing: L("BrewMenu: checking for updates")
        case .ok: L("BrewMenu: all packages up to date")
        case .updates(let count): L("BrewMenu: \(count) updates available")
        case .warning(let count): L("BrewMenu: \(count) doctor warnings")
        case .error: L("BrewMenu: error, click for details")
        }
    }
}
