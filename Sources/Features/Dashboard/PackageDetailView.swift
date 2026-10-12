import AppKit
import BrewCore
import SwiftUI

struct PackageDetailView: View {
    let target: PackageDetailTarget
    let dashboardViewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var filesExpanded = false

    private var isInstalled: Bool {
        dashboardViewModel.isInstalled(target.name)
    }

    private var detail: PackageDetail? {
        dashboardViewModel.packageDetail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if dashboardViewModel.isLoadingPackageDetail {
                LoadingView(fillHeight: true)
            } else if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if detail.deprecated || detail.disabled {
                            statusBanner(detail)
                        }

                        if let desc = detail.desc {
                            Text(desc)
                                .font(.body)
                        }

                        if let homepage = detail.homepage, let url = URL(string: homepage) {
                            Link(homepage, destination: url)
                                .font(.callout)
                        }

                        installCommandRow

                        infoGrid

                        if hasAnalytics {
                            analyticsSection
                        }

                        // Only installed packages have files to show — a not-yet-installed
                        // one has nothing on disk to list.
                        if isInstalled {
                            filesSection
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Text(L("Couldn't load package info"))
                        .foregroundStyle(.secondary)
                    Button(L("Retry")) {
                        dashboardViewModel.selectPackage(name: target.name, isCask: target.isCask)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Spacer()
                footerButton
            }
            .padding()
        }
        .frame(width: 460, height: 520)
        // `selectPackage` is already kicked off by whichever row's info button opened
        // this sheet (it sets `selectedPackageDetailTarget`, which is what triggers the
        // sheet's presentation) — calling it again here on appear used to fire a second,
        // redundant fetch for the same target. Since `selectPackage` only keeps the
        // *last* request's result, if that stray duplicate lost the race after a
        // successful first fetch, the sheet could flip from loaded content to "Couldn't
        // load package info" for no visible reason.
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: target.isCask ? "app.badge" : "terminal")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(verbatim: target.name)
                .font(.title2)
                .fontWeight(.bold)
                .lineLimit(1)
            Spacer()
            Button(L("Done")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Status banner

    private func statusBanner(_ detail: PackageDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(detail.disabled ? L("Disabled") : L("Deprecated"))
            } icon: {
                // Same verified tokens `InstalledPackageRow`/`SearchResultsView` use
                // for this exact distinction — plain `.orange` here used to erase it
                // (both states rendered identically) and fails WCAG non-text contrast
                // besides (≈2.2:1).
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(detail.disabled ? Color.disabledBadge : Color.deprecatedBadge)
            }
            .font(.headline)

            if let reason = detail.deprecationReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let disableDate = detail.disableDate {
                Text(L("Disable date: \(disableDate)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (detail.disabled ? Color.disabledBadge : Color.deprecatedBadge).opacity(0.1),
            in: RoundedRectangle(cornerRadius: CardCornerRadius.small)
        )
    }

    // MARK: - Install command

    private var installCommandRow: some View {
        HStack {
            Text(verbatim: "$ \(detail?.installCommand ?? "")")
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            CopyButton(text: detail?.installCommand ?? "")
        }
        .padding(8)
        .cardBackground(CardCornerRadius.compact)
    }

    // MARK: - Info grid

    private var infoGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let version = detail?.version {
                infoRow(L("Current version"), version)
            }
            if let requirements = detail?.requirements, !requirements.isEmpty {
                infoRow(L("Requirements"), requirements.joined(separator: ", "))
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Analytics

    private var hasAnalytics: Bool {
        guard let detail else { return false }
        return detail.installs30d != nil || detail.installs90d != nil || detail.installs365d != nil
    }

    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L("Installs"))
            VStack(spacing: 0) {
                analyticsRow(L("Last 30 days"), detail?.installs30d)
                Divider()
                analyticsRow(L("Last 90 days"), detail?.installs90d)
                Divider()
                analyticsRow(L("Last 365 days"), detail?.installs365d)
            }
            .cardBackground(CardCornerRadius.small)
        }
    }

    private func analyticsRow(_ label: String, _ count: Int?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(count.map { "\($0)" } ?? "—")
                .fontWeight(.medium)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Files

    /// What this package actually put on disk — collapsed by default (most opens of this
    /// sheet never need it), loaded on first expand rather than whenever the sheet opens,
    /// since it's a real `brew list` subprocess call most visits don't need. No nested
    /// `ScrollView`/`List` here on purpose: this whole pane is already one `ScrollView`
    /// (see `body`), and the file count for a real package is small enough (tens, not
    /// thousands) that appending plain rows reads fine without its own scroll region.
    private var filesSection: some View {
        DisclosureGroup(L("Files"), isExpanded: $filesExpanded) {
            if dashboardViewModel.isLoadingPackageFiles {
                LoadingView()
            } else if let error = dashboardViewModel.packageFilesError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.errorIcon)
            } else if let files = dashboardViewModel.packageFiles {
                VStack(alignment: .leading, spacing: 2) {
                    // Selectable so a path can be copied without a context menu to
                    // build and maintain for just that one action.
                    ForEach(files, id: \.self) { path in
                        Text(verbatim: path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            }
        }
        .onChange(of: filesExpanded) { _, expanded in
            guard expanded else { return }
            dashboardViewModel.loadPackageFiles(name: target.name, isCask: target.isCask)
        }
    }

    // MARK: - Footer action

    private var footerButton: some View {
        Group {
            if isInstalled {
                Label {
                    Text(L("Installed"))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.successIcon)
                }
            } else if dashboardViewModel.installingNames.contains(target.name) {
                VStack(alignment: .trailing, spacing: 4) {
                    if let latest = dashboardViewModel.installLog.last {
                        Text(verbatim: latest)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Button(L("Cancel")) { dashboardViewModel.cancelInstall() }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if dashboardViewModel.failedInstallNames.contains(target.name) {
                        // The real reason from brew, not a generic guess — see
                        // DashboardViewModel.installErrors.
                        Label(
                            dashboardViewModel.installErrors[target.name] ?? L("Install failed"),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(Color.errorIcon)
                        .multilineTextAlignment(.trailing)
                    }
                    Button(dashboardViewModel.failedInstallNames
                        .contains(target.name) ? L("Try Again") : L("Install"))
                    {
                        // Same path Search Results/Trending/Home's Recommended already use
                        // — gives this install the shared log/progress sheet instead of
                        // just a bare spinner, and serializes it against any other install
                        // in flight via `installSingle`'s own `isInstalling` guard (which
                        // no-ops if one's already running — checked before the call so this
                        // sheet only dismisses when it actually started one, same silent
                        // no-op the other callers already have for that case). Dismiss
                        // first: `installSingle` presents DashboardView's InstallLogView
                        // sheet, and two sheets can't be up on the same view at once.
                        let wasIdle = !dashboardViewModel.isInstalling
                        dashboardViewModel.installSingle(name: target.name, isCask: target.isCask)
                        if wasIdle { dismiss() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

// MARK: - CopyButton

/// A copy-to-clipboard button that briefly swaps to a checkmark — without this, the
/// plain "Copy" affordance gave no sign the click actually landed on the pasteboard.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Color.successIcon : .primary)
        .help(L("Copy"))
        .accessibilityLabel(L("Copy"))
    }
}
