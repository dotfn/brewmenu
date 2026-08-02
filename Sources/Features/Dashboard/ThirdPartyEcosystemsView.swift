import SwiftUI

/// Groups every non-Homebrew tap into one browsable list, each under its own
/// tap heading — third-party taps tend to hold just a handful of packages each,
/// so a dedicated sidebar row per tap would clutter Ecosystems fast.
struct ThirdPartyEcosystemsView: View {
    let dashboardViewModel: DashboardViewModel
    @State private var showingAddSheet = false

    private var taps: [Tap] {
        dashboardViewModel.thirdPartyTaps.sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            if taps.isEmpty {
                ContentUnavailableView {
                    Label(L("No third-party taps"), systemImage: "shippingbox.and.arrow.backward")
                } actions: {
                    Button(L("Add…")) { showingAddSheet = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                List {
                    ForEach(taps) { tap in
                        let packages = dashboardViewModel.packages(in: tap).sorted { $0.name < $1.name }
                        Section {
                            if packages.isEmpty {
                                // Nothing installed from this tap yet doesn't mean there's
                                // nothing *to* install — browse what the tap actually
                                // offers (brew tap-info) instead of a dead end.
                                AvailableTapPackagesSection(tap: tap.name, dashboardViewModel: dashboardViewModel)
                            } else {
                                ForEach(packages) { pkg in
                                    InstalledPackageRow(package: pkg, dashboardViewModel: dashboardViewModel)
                                }
                            }
                        } header: {
                            tapSectionHeader(tap: tap, hasNothingInstalled: packages.isEmpty)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        // The toolbar holds the one real action here (Add); the tap count is
        // information, so it goes in the native subtitle slot instead of being
        // stuffed into the toolbar as bare text next to the button.
        .navigationSubtitle(taps.count == 1 ? L("1 tap") : L("\(taps.count) taps"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Label(L("Add…"), systemImage: "plus")
                }
                .help(L("Add a tap, formula, or cask"))
                .accessibilityLabel(L("Add a tap, formula, or cask"))
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddSheet(dashboardViewModel: dashboardViewModel)
        }
    }

    /// A tap with nothing installed from it (whether or not it has anything *to*
    /// install — see `AvailableTapPackagesSection`) is a tap that's easy to add by
    /// mistake or lose interest in; putting "Remove Tap" on the section header itself
    /// means there's always a way out, not just in the narrower case where the tap
    /// also has nothing left to browse.
    @ViewBuilder
    private func tapSectionHeader(tap: Tap, hasNothingInstalled: Bool) -> some View {
        if hasNothingInstalled {
            HStack {
                Text(tap.name)
                Spacer()
                if dashboardViewModel.removingTapNames.contains(tap.name) {
                    ProgressView().controlSize(.small)
                } else {
                    // Bordered, not borderless — a red *button* here (same weight as
                    // ServiceRow's Stop), not red text with no visible chrome.
                    Button(L("Remove Tap")) {
                        Task { await dashboardViewModel.removeTap(tap.name) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .foregroundStyle(.red)
                }
            }
        } else {
            Text(tap.name)
        }
    }
}

/// One field for three different actions: paste a tap (`user/repo`), a bare formula/cask
/// name (`wget`), or a full path into a tap you haven't added yet (`user/repo/name`) —
/// Homebrew's own naming rules make the three unambiguous (see `AddInputKind`), so the
/// field classifies as you type and walks you to the right next step instead of asking
/// you to pick "tap" or "package" up front. A formula/cask candidate is looked up via
/// `brew info` first — showing what it actually is (formula or cask, its tap, its
/// description) and letting you confirm — before anything is installed.
private struct AddSheet: View {
    let dashboardViewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private var kind: AddInputKind { dashboardViewModel.addInputKind }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Add"))
                .font(.title3)
                .fontWeight(.bold)

            Text(L("Paste a tap (user/repo), a formula or cask name (wget), or a full path from a tap you haven't added yet (user/repo/name). BrewMenu figures out which."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(L("user/repo, wget, or user/repo/name"), text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(isBusy)
                .onChange(of: input) { _, newValue in
                    // If the user pasted a whole command (e.g. "brew install --cask
                    // user/repo/name" copied from this app's own detail sheet, or from
                    // Homebrew's website), collapse it down to the bare identifier —
                    // visibly, so what's shown always matches what will actually happen.
                    let cleaned = dashboardViewModel.updateAddInput(newValue)
                    if cleaned != newValue { input = cleaned }
                }
                .onSubmit { Task { await submitPrimary() } }

            statusArea
                .frame(minHeight: 34, alignment: .top)

            HStack {
                Spacer()
                // Never disabled, even mid-lookup/install — a hung `brew info`/`brew tap`
                // call used to leave this as the user's only control, disabled right
                // alongside the text field, with no way out of the sheet at all.
                Button(L("Cancel")) { dismiss() }
                    .buttonStyle(.bordered)
                primaryButton
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { dashboardViewModel.updateAddInput(input) }
    }

    private var isBusy: Bool {
        dashboardViewModel.isResolvingPackage || dashboardViewModel.isAddingTap
            || (currentCandidateName.map { dashboardViewModel.installingNames.contains($0) } ?? false)
    }

    private var currentCandidateName: String? {
        if case .packageCandidate(let name) = kind { return name }
        return nil
    }

    // MARK: - Status (keeps the user aware of exactly what's about to happen)

    @ViewBuilder
    private var statusArea: some View {
        switch kind {
        case .invalid:
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(L("Enter a tap (user/repo), a package name, or a full path (user/repo/name)."), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .tap(let name):
            Label(L("This adds the tap \"\(name)\" — a source for extra formulae and casks."), systemImage: "shippingbox")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = dashboardViewModel.addTapError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        case .packageCandidate(let name):
            if dashboardViewModel.isResolvingPackage {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Looking up \"\(name)\"…")).font(.caption).foregroundStyle(.secondary)
                }
            } else if let resolved = dashboardViewModel.resolvedPackage {
                resolvedPreview(resolved, requestedAs: name)
            } else if let error = dashboardViewModel.resolvePackageError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(L("Press Return to look this up."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resolvedPreview(_ resolved: ResolvedPackage, requestedAs name: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: resolved.isCask ? "app.badge" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: resolved.name)
                        .font(.system(.callout, design: .monospaced))
                    Text(resolved.isCask ? L("Cask") : L("Formula"))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.2), in: Capsule())
                }
                if let desc = resolved.desc {
                    Text(verbatim: desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(resolved.tap)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if resolved.didAutoTap {
                    // `brew info` needed the tap to already exist to look this up, so
                    // resolving it just now tapped it — a real, if small, side effect of
                    // a step that otherwise looks like "just checking." Say so.
                    Label(L("Added the tap \"\(resolved.tap)\" to look this up."), systemImage: "shippingbox")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if dashboardViewModel.isInstalled(resolved.name) {
                Label(L("Installed"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help(L("Installed"))
            } else if dashboardViewModel.failedInstallNames.contains(name) {
                // The real reason from brew (e.g. "there's already an App at
                // /Applications/X.app") — a generic "check the name" message here
                // sent users chasing a typo that was never the actual problem.
                Label(dashboardViewModel.installErrors[name] ?? L("Install failed — check the name and try again."), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Primary action (label always matches what will actually happen)

    @ViewBuilder
    private var primaryButton: some View {
        switch kind {
        case .invalid:
            Button(L("Add")) {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
        case .tap:
            if dashboardViewModel.isAddingTap {
                ProgressView().controlSize(.small)
            } else {
                Button(L("Add Tap")) { Task { await submitPrimary() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .packageCandidate(let name):
            if dashboardViewModel.installingNames.contains(name) {
                ProgressView().controlSize(.small)
            } else if let resolved = dashboardViewModel.resolvedPackage {
                if dashboardViewModel.isInstalled(resolved.name) {
                    Button(L("Done")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(dashboardViewModel.failedInstallNames.contains(name) ? L("Try Again") : L("Install")) {
                        Task { await submitPrimary() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Button(L("Look Up")) { Task { await submitPrimary() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(dashboardViewModel.isResolvingPackage)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    /// Drives both the text field's Return key and the button below it through the
    /// same guided sequence: an unresolved package candidate first looks itself up: only
    /// once its type is confirmed does the same action install it — so a mistyped name
    /// is caught before anything is downloaded, and a real tap or install never happens
    /// on a single accidental keystroke.
    private func submitPrimary() async {
        switch kind {
        case .invalid:
            return
        case .tap(let name):
            if await dashboardViewModel.addTap(name) { dismiss() }
        case .packageCandidate(let name):
            if let resolved = dashboardViewModel.resolvedPackage {
                guard !dashboardViewModel.isInstalled(resolved.name) else { return }
                await dashboardViewModel.install(name: name, isCask: resolved.isCask)
                if !dashboardViewModel.failedInstallNames.contains(name) { dismiss() }
            } else {
                await dashboardViewModel.resolvePackageCandidate(name)
            }
        }
    }
}

// MARK: - AvailableTapPackagesSection

/// Fills in a tap section that has nothing installed from it yet with what the
/// tap actually offers (`brew tap-info`), so there's something to browse and
/// install instead of a dead end.
private struct AvailableTapPackagesSection: View {
    let tap: String
    let dashboardViewModel: DashboardViewModel
    // Local, not read from dashboardViewModel — see the comment on
    // DashboardViewModel.loadingTapPackagesFor for why routing this through
    // shared @Observable state created a SwiftUI attribute-graph feedback loop.
    @State private var isLoading = false

    private var available: [SearchResult]? { dashboardViewModel.tapPackages[tap] }
    private var loadError: String? { dashboardViewModel.tapPackagesError[tap] }

    var body: some View {
        Group {
            if let available, !available.isEmpty {
                ForEach(available) { result in
                    AvailableTapPackageRow(result: result, tap: tap, dashboardViewModel: dashboardViewModel)
                }
            } else if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Looking up available packages…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(minHeight: 20, alignment: .leading)
            } else if let loadError {
                // Distinct from the genuine "nothing in this tap" state below — a
                // failed `brew tap-info` call used to be swallowed into the same empty
                // state and cached forever, so a tap that really does have packages
                // (confirmed: a real network hiccup or transient brew error) looked
                // permanently, indistinguishably empty with no way to try again.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button(L("Retry")) {
                        Task { await dashboardViewModel.loadTapPackages(for: tap) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(minHeight: 20, alignment: .leading)
            } else {
                // Nothing installed *and* nothing to browse (tap-info genuinely came
                // back empty) — the section header's own "Remove Tap" (shown whenever
                // nothing's installed from this tap) is the way out here; no need to
                // duplicate that button inline too.
                Text(L("No packages installed from this tap yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 20, alignment: .leading)
            }
        }
        .task(id: tap) {
            guard dashboardViewModel.tapPackages[tap] == nil else { return }
            isLoading = true
            await dashboardViewModel.loadTapPackages(for: tap)
            isLoading = false
        }
    }
}

private struct AvailableTapPackageRow: View {
    let result: SearchResult
    let tap: String
    let dashboardViewModel: DashboardViewModel

    // Narrower than before now that this column holds a fixed 24pt icon instead of a
    // variable-width text pill.
    @ScaledMetric(relativeTo: .caption) private var statusColumnWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: result.isCask ? "app.badge" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(verbatim: result.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 12)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(result.name)

            Button {
                dashboardViewModel.selectPackage(name: result.name, isCask: result.isCask, tap: tap)
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
            .help(L("Package info"))
            .accessibilityLabel(L("Package info for \(result.name)"))

            PackageStatusIndicator(name: result.name, isCask: result.isCask, dashboardViewModel: dashboardViewModel)
                .frame(width: statusColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}
