import AppKit
import BrewCore
import SwiftUI

/// A package's page, opened on top of the list it was picked from — the App Store's product page,
/// for Homebrew: a large header with the action pill, then what Homebrew knows about it.
///
/// The header paints at once from the catalog; formulae.brew.sh's per-package data (requirements,
/// deprecation reason, install counts) fills in below as it arrives.
struct PackageDetailView: View {
    let target: PackageDetailTarget
    let dashboardViewModel: DashboardViewModel
    @State private var filesExpanded = false

    private var package: CatalogPackage {
        catalogEntry(target.qualifiedName, isCask: target.isCask, in: dashboardViewModel.store)
    }

    private var isInstalled: Bool {
        dashboardViewModel.isInstalled(target.name)
    }

    private var installedVersion: String? {
        dashboardViewModel.store.installedPackage(named: target.name)?.version
    }

    /// Homebrew's newest version — `brew outdated`'s own answer when it lists the package, which is
    /// what an Update installs; otherwise formulae.brew.sh's, then the catalog's.
    private var latestVersion: String? {
        let outdated = dashboardViewModel.store.outdated.first { $0.name == target.name }
        let version = outdated?.currentVersion ?? detail?.version ?? package.version
        return version.isEmpty ? nil : version
    }

    private var isOutdated: Bool {
        isInstalled && dashboardViewModel.isOutdated(target.name)
    }

    /// Only this page's own data: the view model holds one package's detail at a time.
    private var detail: PackageDetail? {
        dashboardViewModel.selectedPackageDetailTarget == target ? dashboardViewModel.packageDetail : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if let detail, detail.deprecated || detail.disabled {
                    statusBanner(detail)
                }

                if detail == nil, dashboardViewModel.isLoadingPackageDetail {
                    LoadingView()
                } else if detail == nil {
                    HStack {
                        Text(L("Couldn't load package info"))
                            .foregroundStyle(.secondary)
                        Button(L("Retry")) { load() }
                            .buttonStyle(.roomyBordered)
                            .controlSize(.small)
                    }
                }

                informationSection

                if hasAnalytics {
                    analyticsSection
                }

                // Only installed packages have files to show — a not-yet-installed one has
                // nothing on disk to list.
                if isInstalled {
                    filesSection
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(package.displayName)
        // Loads when the page opens; going back and forth to the same package doesn't refetch.
        .task(id: target) {
            if dashboardViewModel.selectedPackageDetailTarget != target { load() }
        }
    }

    private func load() {
        dashboardViewModel.selectPackage(name: target.name, isCask: target.isCask, tap: target.tap)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            PackageIcon(
                name: package.name,
                displayName: package.displayName,
                isCask: package.isCask,
                appPath: package.appPath,
                size: 128
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: package.displayName)
                    .font(.largeTitle.bold())
                    .textSelection(.enabled)
                if let desc = package.desc ?? detail?.desc {
                    Text(verbatim: desc)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                // What's on this Mac, next to what kind of package it is. `.secondary`, not
                // `.tertiary`: the dimmer one falls under 4.5:1 on the dark window. The tap is in
                // Information below, so it isn't repeated here.
                Text(verbatim: statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                StoreActionButton(
                    name: package.name,
                    isCask: package.isCask,
                    isDisabledUpstream: package.disabled || detail?.disabled == true,
                    offersUninstallWhenOutdated: true
                )
                .controlSize(.large)
                .padding(.top, 10)

                if let error = dashboardViewModel.installErrors[target.name] {
                    // The real reason from brew, not a generic guess — see
                    // DashboardViewModel.installErrors.
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.errorIcon)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var kindTitle: String {
        target.isCask ? (package.isApp ? L("App") : L("Cask")) : L("Command-line tool")
    }

    /// "Cask · Installed 1.2 · 1.3 available": what Update would actually do, before pressing it.
    private var statusLine: String {
        var parts = [kindTitle]
        if let installedVersion {
            parts.append(L("Installed \(installedVersion)"))
            if isOutdated, let latestVersion, latestVersion != installedVersion {
                parts.append(L("\(latestVersion) available"))
            }
        }
        return parts.joined(separator: " · ")
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

    // MARK: - Information

    /// The App Store's "Information" block: label over value, in columns.
    private var informationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StoreSectionHeader(title: L("Information"))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: 24, alignment: .topLeading)],
                alignment: .leading,
                spacing: 16
            ) {
                infoCell(L("Name"), package.name)
                infoCell(L("Tap"), package.tap)
                if let installedVersion {
                    infoCell(L("Installed version"), installedVersion)
                }
                if let latestVersion {
                    infoCell(L("Latest version"), latestVersion)
                }
                if let requirements = detail?.requirements, !requirements.isEmpty {
                    infoCell(L("Requirements"), requirements.joined(separator: ", "))
                }
                if let homepage = detail?.homepage ?? package.homepage, let url = URL(string: homepage) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Homepage"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link(url.host() ?? homepage, destination: url)
                            .font(.callout)
                            .help(homepage)
                    }
                }
            }
            .padding(16)
            .cardBackground()
            installCommandRow
        }
    }

    private func infoCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    /// The command for what this page offers to do: install it, or — once it's here and behind —
    /// upgrade it. "brew install" for a package that's already installed did nothing useful.
    private var installCommand: String {
        let name = target.tap.map { tap in
            ["homebrew/core", "homebrew/cask"].contains(tap) ? target.name : "\(tap)/\(target.name)"
        } ?? target.name
        let verb = isOutdated ? "upgrade" : "install"
        return target.isCask ? "brew \(verb) --cask \(name)" : "brew \(verb) \(name)"
    }

    private var installCommandRow: some View {
        HStack {
            Text(verbatim: "$ \(installCommand)")
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            CopyButton(text: installCommand)
        }
        .padding(10)
        .cardBackground(CardCornerRadius.compact)
    }

    // MARK: - Installs

    private var hasAnalytics: Bool {
        guard let detail else { return false }
        return detail.installs30d != nil || detail.installs90d != nil || detail.installs365d != nil
    }

    /// Three figures side by side, like the App Store's ratings strip.
    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            StoreSectionHeader(title: L("Installs"))
            HStack(spacing: 0) {
                analyticsCell(L("Last 30 days"), detail?.installs30d)
                Divider().frame(height: 44)
                analyticsCell(L("Last 90 days"), detail?.installs90d)
                Divider().frame(height: 44)
                analyticsCell(L("Last 365 days"), detail?.installs365d)
            }
        }
    }

    private func analyticsCell(_ label: String, _ count: Int?) -> some View {
        VStack(spacing: 4) {
            Text(count.map { $0.formatted(.number.notation(.compactName)) } ?? "—")
                .font(.title2.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Files

    /// What this package actually put on disk — collapsed by default (most visits never need
    /// it), loaded on first expand rather than whenever the page opens, since it's a real
    /// `brew list` subprocess call. No nested `ScrollView`/`List` here on purpose: the whole
    /// page is already one `ScrollView`, and a real package's file count is small enough (tens,
    /// not thousands) that plain rows read fine without their own scroll region.
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
        .font(.title3.weight(.semibold))
        .onChange(of: filesExpanded) { _, expanded in
            guard expanded else { return }
            dashboardViewModel.loadPackageFiles(name: target.name, isCask: target.isCask)
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
