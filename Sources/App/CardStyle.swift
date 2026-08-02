import SwiftUI

/// Corner-radius scale for card-like containers, so every card in the app pulls
/// from the same named steps instead of repeating magic numbers that can drift
/// apart. Radius grows with the container's size (same principle as Apple's
/// concentric-corner guidance) — a tiny inline chip and a large tappable tile
/// aren't supposed to share a radius, but which step each one uses should be a
/// deliberate, visible choice, not an arbitrary literal.
enum CardCornerRadius {
    /// Home dashboard's large, directly-tappable StatCard tiles.
    static let large: CGFloat = 12
    /// Content cards (Trending list container, Recommended card, Install Pack card).
    static let medium: CGFloat = 10
    /// Inline info blocks inside sheets (status banner, analytics section).
    static let small: CGFloat = 8
    /// The smallest inline chip (the install-command row).
    static let compact: CGFloat = 6
}
