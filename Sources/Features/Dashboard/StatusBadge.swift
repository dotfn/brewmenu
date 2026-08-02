import SwiftUI

/// A small pill-shaped status label (e.g. "Outdated") — shared so every browse view
/// (Installed, Ecosystems, Categories, Trending, Recommended, Search) renders it
/// identically instead of each hand-rolling its own badge with its own contrast.
struct StatusBadge: View {
    let text: String
    var color: Color = .outdatedBadge

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

extension Color {
    /// A darker orange than `.orange` — plain `.orange` text/fill fails WCAG AA
    /// (≈2.1:1 against light or dark backgrounds). White text on this shade measures
    /// ≈4.52:1, just clearing the 4.5:1 minimum for normal-size text.
    static let outdatedBadge = Color(red: 0.75, green: 0.35, blue: 0.0)

    /// Darker goldenrod for "Deprecated" — white text measures ≈5.86:1.
    static let deprecatedBadge = Color(red: 0.51, green: 0.37, blue: 0.0)

    /// Dark red for "Disabled" (more severe than deprecated — disabled formulae/casks
    /// can fail to install) — white text measures ≈8.72:1.
    static let disabledBadge = Color(red: 0.59, green: 0.08, blue: 0.08)

    /// Darker green for "Installed" — plain `.green` is too bright for white text
    /// (fails WCAG AA, same problem `.outdatedBadge` fixed for orange). White text
    /// on this shade measures ≈6.1:1.
    static let installedBadge = Color(red: 0.0, green: 0.45, blue: 0.12)
}

/// A fixed 24×24 colored icon standing in for a package's status — every state in
/// this column (installed, outdated, installing, install) now occupies the exact
/// same footprint, matching the row's own info button, instead of a capsule whose
/// width tracked its label's character count ("Installed" vs. "Outdated") sitting
/// next to a still-differently-shaped "Install" button.
private struct StatusIcon: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
    }
}

/// The trailing status indicator shared by every "might already be installed"
/// browse row (Trending, Search Results, Available Tap Packages).
struct PackageStatusIndicator: View {
    let name: String
    let isCask: Bool
    let dashboardViewModel: DashboardViewModel

    private var isInstalled: Bool { dashboardViewModel.isInstalled(name) }
    private var isOutdated: Bool { dashboardViewModel.isOutdated(name) }
    private var failed: Bool { dashboardViewModel.failedInstallNames.contains(name) }

    var body: some View {
        if isInstalled && isOutdated {
            StatusIcon(systemImage: "arrow.up.circle.fill", color: .outdatedBadge)
                .help(L("Outdated"))
                .accessibilityLabel(L("Outdated"))
        } else if isInstalled {
            StatusIcon(systemImage: "checkmark.circle.fill", color: .installedBadge)
                .help(L("Installed"))
                .accessibilityLabel(L("Installed"))
        } else if dashboardViewModel.installingNames.contains(name) {
            ProgressView().controlSize(.small)
                .frame(width: 24, height: 24)
                .accessibilityLabel(L("Installing \(name)"))
        } else {
            Button {
                Task { await dashboardViewModel.install(name: name, isCask: isCask) }
            } label: {
                Image(systemName: failed ? "exclamationmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(failed ? .red : .accentColor)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .help(failed ? L("Try Again") : L("Install"))
            .accessibilityLabel(failed ? L("Retry installing \(name)") : L("Install \(name)"))
        }
    }
}
