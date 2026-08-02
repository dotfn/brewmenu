import SwiftUI

struct InstalledPackageRow: View {
    let package: InstalledPackage
    var dashboardViewModel: DashboardViewModel? = nil

    @State private var showingUninstallConfirmation = false

    // Scales with the system Text Size setting rather than staying a literal point
    // value, so this column doesn't clip the version string at larger accessibility sizes.
    @ScaledMetric(relativeTo: .caption) private var versionColumnWidth: CGFloat = 76

    /// Homebrew cask versions are often "1.2.3,03c61d0…2ba62e" — a build hash tacked on
    /// after a comma. That hash is noise in a compact list; the tooltip (`.help`) still
    /// shows the full string for anyone who needs it.
    private var shortVersion: String {
        if let commaIndex = package.version.firstIndex(of: ",") {
            return String(package.version[..<commaIndex])
        }
        return package.version
    }

    private var accessibilitySummary: String {
        var parts = [package.name]
        if let desc = package.desc { parts.append(desc) }
        if package.pinned { parts.append(L("pinned")) }
        if package.disabled { parts.append(L("disabled")) }
        else if package.deprecated { parts.append(L("deprecated")) }
        if package.outdated { parts.append(L("outdated")) }
        parts.append(L("version \(shortVersion)"))
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 10) {
            // Grouped as one VoiceOver stop (icon + name + desc + status + version) so
            // navigating the list reads one coherent row instead of five disconnected
            // fragments — the info button stays a separate, individually-reachable element.
            HStack(spacing: 10) {
                Image(systemName: package.isCask ? "app.badge" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        // A triangle right next to the name — same treatment as the pin —
                        // so a deprecated/disabled package is obvious while scanning a
                        // list, not just visible after opening its detail sheet.
                        if package.disabled || package.deprecated {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(package.disabled ? Color.disabledBadge : Color.deprecatedBadge)
                                .help(package.disableReason ?? package.deprecationReason ?? "")
                        }
                        Text(verbatim: package.name)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                        if package.pinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let desc = package.desc {
                        Text(verbatim: desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 12)

                if package.disabled {
                    StatusBadge(text: L("Disabled"), color: .disabledBadge)
                } else if package.deprecated {
                    StatusBadge(text: L("Deprecated"), color: .deprecatedBadge)
                }
                if package.outdated {
                    StatusBadge(text: L("Outdated"))
                }

                Text(verbatim: shortVersion)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: versionColumnWidth, alignment: .trailing)
                    .help(package.version)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)

            if let dashboardViewModel {
                if dashboardViewModel.uninstallingNames.contains(package.name) {
                    ProgressView().controlSize(.small)
                        .frame(minWidth: 24, minHeight: 24)
                        .accessibilityLabel(L("Uninstalling \(package.name)"))
                } else {
                    Button {
                        showingUninstallConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(dashboardViewModel.failedUninstallNames.contains(package.name) ? .red : .secondary)
                    .frame(minWidth: 24, minHeight: 24)
                    .contentShape(Rectangle())
                    .help(dashboardViewModel.failedUninstallNames.contains(package.name) ? L("Uninstall failed — try again") : L("Uninstall"))
                    .accessibilityLabel(L("Uninstall \(package.name)"))
                    .confirmationDialog(
                        L("Uninstall \(package.name)?"),
                        isPresented: $showingUninstallConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(L("Uninstall"), role: .destructive) {
                            Task { await dashboardViewModel.uninstall(name: package.name, isCask: package.isCask) }
                        }
                        Button(L("Cancel"), role: .cancel) {}
                    } message: {
                        Text(L("This removes \(package.name) from your Mac. You can reinstall it anytime."))
                    }
                }

                Button {
                    dashboardViewModel.selectPackage(name: package.name, isCask: package.isCask, tap: package.tap)
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
                .help(L("Package info"))
                .accessibilityLabel(L("Package info for \(package.name)"))
            }
        }
        .padding(.vertical, 4)
    }
}
