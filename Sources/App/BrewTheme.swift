import SwiftUI

/// Shared design tokens, ported from `Homebrew/BrewUI`'s own design system
/// (`HOMEBREW-INTERNALS.md` section B6) — the official Homebrew app, so these are
/// Homebrew's own verified brand/contrast choices, not invented here.
///
/// What was deliberately *not* ported: BrewUI's badge tokens
/// (`badge.outdated.background/.foreground`) use a subtle tinted background with
/// colored text; `StatusBadge` here uses a solid fill with white text — a different
/// component pattern. Swapping only the color value without the pattern would mean
/// reusing a foreground color as a fill, which was never contrast-checked for that
/// combination. `StatusBadge`'s existing colors (`Color.outdatedBadge` etc.) already
/// carry their own verified white-text-on-fill contrast ratios (see `StatusBadge.swift`)
/// and are left untouched.
///
/// What *is* ported: the brand accent itself, and BrewUI's hard rule for using it —
/// system accent color (`.tint(.accentColor)`, the default) on every standard SwiftUI
/// control (`Button(.borderedProminent)`, `Toggle`, `Picker`, focus rings — macOS
/// doesn't expose whether the user customized their system accent, so there's no way
/// to fall back to amber "only when it's the default"), and `Color.brewAccent` only on
/// fully custom, app-drawn elements where `.tint()` has no system control to respect
/// (the menu bar icon, progress fills). Applying amber to a standard `.borderedProminent`
/// button — which this app uses throughout — would violate that exact rule, so none of
/// the existing `.buttonStyle(.borderedProminent)` call sites were changed.
enum BrewTheme {
    /// Homebrew's brand amber (`Amber 500` in BrewUI's palette). Same value in light
    /// and dark mode — it's used as a filled surface/glyph color, not blended into a
    /// background that would need different treatment per appearance.
    static let accent = Color(red: 0xFB / 255, green: 0xB0 / 255, blue: 0x40 / 255)
}

/// 8pt spacing grid (BrewUI's `spacing.*` tokens), with a 4pt half-step. Additive: existing
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
