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

/// The trailing status indicator shared by every "might already be installed"
/// browse row (Trending, Search Results, Available Tap Packages).
struct PackageStatusIndicator: View {
    let name: String
    let isCask: Bool
    @Environment(DashboardViewModel.self) private var dashboardViewModel

    private var isInstalled: Bool { dashboardViewModel.isInstalled(name) }
    private var isOutdated: Bool { dashboardViewModel.isOutdated(name) }
    private var failed: Bool { dashboardViewModel.failedInstallNames.contains(name) }

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
            .foregroundStyle(failed ? .red : .accentColor)
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
    @State private var showingUninstallConfirmation = false

    private var failedUninstall: Bool { dashboardViewModel.failedUninstallNames.contains(name) }

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
            .foregroundStyle(isHovering || failedUninstall ? .red : .secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .help(dashboardViewModel.uninstallErrors[name] ?? (isOutdated ? L("Outdated — click to uninstall") : L("Installed — click to uninstall")))
            .accessibilityLabel(L("Uninstall \(name)"))
            .confirmationDialog(
                L("Uninstall \(name)?"),
                isPresented: $showingUninstallConfirmation,
                titleVisibility: .visible
            ) {
                Button(L("Uninstall"), role: .destructive) {
                    Task { await dashboardViewModel.uninstall(name: name, isCask: isCask) }
                }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(L("This removes \(name) from your Mac. You can reinstall it anytime."))
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
    var tap: String? = nil
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
struct PackageBrowseRow: View {
    let name: String
    let isCask: Bool
    var tap: String? = nil
    var accessibilityLabel: String? = nil
    var leading: AnyView? = nil
    var trailing: AnyView? = nil

    // Narrower than a variable-width text pill needed, now that this column holds a
    // fixed 24pt icon.
    @ScaledMetric(relativeTo: .caption) private var statusColumnWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isCask ? "app.badge" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                leading
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
