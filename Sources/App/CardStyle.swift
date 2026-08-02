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

extension View {
    /// The one card fill every card-like container in the app uses — same
    /// `.quaternary.opacity(0.4)` tint at whichever `CardCornerRadius` step fits the
    /// container, so a call site can't drift onto a slightly different opacity/color.
    func cardBackground(_ radius: CGFloat = CardCornerRadius.medium) -> some View {
        background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: radius))
    }
}

/// The centered "still loading" spinner shared by every screen that needs to
/// distinguish "loading" from "genuinely empty" (Home, Installed, Package Detail,
/// Search) — each used to hand-roll its own identical Spacer/ProgressView/Spacer stack.
struct LoadingView: View {
    var label: String? = nil
    /// Package Detail and Search fill their whole pane (no other content below);
    /// Home and Installed sit above content that reserves its own height, so only
    /// centering horizontally (not vertically) keeps their layout as it was.
    var fillHeight: Bool = false

    var body: some View {
        VStack {
            Spacer()
            if let label {
                ProgressView(label)
            } else {
                ProgressView()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil)
    }
}

/// The "BrewMenu updated — restart to apply" banner, shown identically in the popover
/// (`MenuBarView`) and the Dashboard window (`DashboardView`) whenever `needsRestart`
/// is true — a user who upgrades from either window needs to see it. Padding is the
/// one deliberate difference between the two: the popover's tighter chrome vs. the
/// Dashboard's more spacious window, same as `HomeView`'s `.headline` vs. `MenuBarView`'s
/// compact `groupLabel`.
struct RestartBanner: View {
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .foregroundStyle(.orange)
            Text(L("BrewMenu updated — restart to apply"))
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            Button(L("Restart")) { AppRelauncher.restart() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .combine)
    }
}

/// The filled, rounded search field used for filtering a package list — shared by
/// `InstalledView` (Dashboard) and `MenuBarView` (popover) instead of each hand-rolling
/// the same icon/TextField/clear-button/background stack.
struct SearchField: View {
    @Binding var text: String
    var prompt: String = L("Search package…")

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: CardCornerRadius.small))
    }
}

/// The title text introducing a group of rows/cards — "Trending in Homebrew", a
/// tap's own heading in Third-Party, "Installs" in Package Detail, "Services" in the
/// popover. Before this, each screen invented its own font/weight/color for that job
/// (an explicit `.headline` here, a default List section-header font there, a manual
/// `.caption`/`.semibold`/`.secondary` stack somewhere else), which is what made two
/// adjacent-looking headers — a List `Section` header and a plain `Text` header — draw
/// with different system chrome (and, for List headers specifically, a different
/// separator underneath). One shared title style now; only `.compact` is a deliberate
/// exception, not a fourth accidental variant: the popover stacks up to four different
/// content groups in one scroll, so its labels need to read as dividers between them,
/// not as page titles fighting the rows below (see `MenuBarView.groupLabel`, which
/// still owns its own padding — layout stays with the caller, since a List's own
/// Section-header insets and a plain VStack's spacing aren't the same thing).
///
/// No `.glassEffect()` here, on either scale, on any OS — Apple's own Liquid Glass
/// guidance draws a hard line between the **navigation layer** (tab bars, sidebars,
/// toolbars — gets glass) and the **content layer** (list rows, section headers —
/// doesn't): "glass on the content layer blurs the boundary and competes with
/// navigation." A section header introducing a group of cards/rows is content, not
/// navigation, on every screen it appears — Home's cards, Third-Party's per-tap
/// headings, Package Detail's "Installs", the popover's group labels. (An earlier
/// version of this wrapped `.standard` in a floating glass capsule; that read as a
/// narrow, oddly-placed pill competing with the real navigation chrome around it —
/// exactly the failure mode the guidance describes.)
struct SectionHeader: View {
    enum Scale {
        /// Dashboard window content — Home's cards, Third-Party's per-tap headings,
        /// Package Detail's "Installs".
        case standard
        /// The popover's compact, space-constrained panel.
        case compact
    }

    let title: String
    var scale: Scale = .standard

    var body: some View {
        switch scale {
        case .standard:
            Text(title).font(.headline)
        case .compact:
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }
}
