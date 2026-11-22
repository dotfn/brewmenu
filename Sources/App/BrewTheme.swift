import AppKit
import SwiftUI

/// Shared design tokens: Homebrew's brand accent, the popover's base fill and a spacing grid.
///
/// Badges aren't here: `StatusBadge` uses a solid fill with white text, and its colors
/// (`Color.outdatedBadge` etc.) carry their own verified white-text-on-fill contrast ratios
/// (see `StatusBadge.swift`). A tinted-background, colored-text badge color dropped in without
/// that pattern would put a foreground color behind white text, a pairing never checked for
/// contrast.
///
/// The accent comes with one rule for using it — the
/// system accent color (`.tint(.accentColor)`, the default) on every standard SwiftUI
/// control (`Button(.borderedProminent)`, `Toggle`, `Picker`, focus rings — macOS
/// doesn't expose whether the user customized their system accent, so there's no way
/// to fall back to amber "only when it's the default"), and `BrewTheme.accent` only on
/// fully custom, app-drawn elements where `.tint()` has no system control to respect
/// (the menu bar icon, progress fills). Applying amber to a standard `.borderedProminent`
/// button — which this app uses throughout — would violate that exact rule, so none of
/// the existing `.buttonStyle(.roomyBorderedProminent)` call sites were changed.
enum BrewTheme {
    /// Homebrew's brand amber. Same value in light
    /// and dark mode — it's used as a filled surface/glyph color, not blended into a
    /// background that would need different treatment per appearance.
    static let accent = Color(red: 0xFB / 255, green: 0xB0 / 255, blue: 0x40 / 255)
}

extension Color {
    /// The menu bar popover's own base fill, under everything it draws. Not a literal RGB value: it
    /// tracks `NSColor.windowBackgroundColor`, which already adapts to light/dark
    /// mode on its own. Needed because `MenuBarExtra(.window)` renders its content
    /// with no background of its own by default — confirmed against a real
    /// screenshot, its material picked up a strong tint from a custom System
    /// Settings → Appearance accent color instead of staying neutral. This has
    /// nothing to do with any `.tint()`/`.accentColor` call in this app's own
    /// code (there's no root-level tint override anywhere, by design — see the
    /// system-accent rule above); it was macOS's own default material reacting to
    /// the user's own accent choice with nothing in SwiftUI asking it not to.
    static let brewWindowBackground = Color(nsColor: .windowBackgroundColor)
}

/// 8pt spacing grid, with a 4pt half-step. Additive: existing
/// call sites keep their literal values until touched; new layout code should reach for
/// these instead of a fresh magic number.
enum BrewSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}
