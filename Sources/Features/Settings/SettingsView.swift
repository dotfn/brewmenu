import AppKit
import BrewCore
import SwiftUI

// MARK: - Settings page

/// Every setting on one page, the sidebar's single Settings destination. General, Notifications
/// and About used to be three sidebar entries, each a short page of its own: a few toggles each,
/// and a jump between entries to see the rest.
///
/// One grouped form, in the order people reach for things: how the app behaves, where Homebrew
/// is, what it tells you, what it is — and the one destructive action last, on its own.
struct SettingsPage: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            GeneralSettings(viewModel: viewModel)
            BrewPathSettings(viewModel: viewModel)
            NotificationSettings(viewModel: viewModel)
            AboutSettings()
            ResetDataSettings(viewModel: viewModel)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
        // Toggles/pickers above save via SettingsViewModel.settings's own didSet ->
        // scheduleSave() (debounced internally, no view-level mirroring) — if that write
        // fails (disk full, permissions), the control had already flipped visually with
        // nothing telling the user it didn't actually persist. Surfaced here instead of
        // silently discarded.
        .alert(
            L("Couldn't save settings"),
            isPresented: Binding(
                get: { viewModel.saveError != nil },
                set: { if !$0 { viewModel.saveError = nil } }
            )
        ) {
            Button(L("OK")) { viewModel.saveError = nil }
        } message: {
            Text(viewModel.saveError ?? "")
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section(L("General")) {
            Toggle(L("Open at login"), isOn: $viewModel.settings.launchAtLogin)
            Toggle(L("Show upgrade count"), isOn: $viewModel.settings.showUpdateBadge)
            Toggle(
                L("Hide menu bar icon when nothing needs attention"),
                isOn: $viewModel.settings.hideMenuBarIconWhenClear
            )

            Picker(L("Check frequency"), selection: $viewModel.settings.checkInterval) {
                ForEach(AppSettings.CheckInterval.allCases, id: \.self) { interval in
                    Text(verbatim: interval.displayName).tag(interval)
                }
            }
        }
    }
}

// MARK: - Homebrew path

private struct BrewPathSettings: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section {
            HStack(spacing: 6) {
                TextField(
                    text: Binding(
                        get: { viewModel.settings.customBrewPath ?? "" },
                        set: { viewModel.settings.customBrewPath = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text(verbatim: "/opt/homebrew/bin/brew")
                ) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .labelsHidden()
                Button(L("Browse…")) {
                    if let path = BrewExecutablePicker.pick() { viewModel.settings.customBrewPath = path }
                }
                if viewModel.settings.customBrewPath != nil {
                    Button { viewModel.settings.customBrewPath = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("Reset to default path"))
                }
            }
        } header: {
            Text(L("Homebrew path"))
        } footer: {
            if viewModel.brewPathIsValid {
                Text(L("Leave empty to use the default path."))
            } else {
                Text(L("No executable file at this path."))
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationSettings: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section(L("Notifications")) {
            Toggle(L("Notify on new upgrades"), isOn: $viewModel.settings.notifyOnUpdates)
            Toggle(L("Notify on upgrade failure"), isOn: $viewModel.settings.notifyOnUpgradeFailure)
            Toggle(L("Notify on new doctor warnings"), isOn: $viewModel.settings.notifyOnDoctorWarnings)
            Toggle(L("Notify on critical insights"), isOn: $viewModel.settings.notifyOnCriticalInsights)
        }
    }
}

// MARK: - About

/// What's running and who made it, as rows like every other section — it was a page of its own,
/// centered in an otherwise empty window.
private struct AboutSettings: View {
    var body: some View {
        Section(L("About")) {
            HStack(spacing: 14) {
                // The app's real icon, not a generic SF Symbol standing in for it (see `AppInfo.icon`).
                Image(nsImage: AppInfo.icon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: AppInfo.name)
                        .font(.headline)
                    Text(L("Homebrew health monitor for macOS"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L("Version \(AppInfo.version)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                // A free, one-click way to support the project, next to the version everyone
                // on this section already has in view. A Button (not Link) so .buttonStyle
                // applies — Link ignores it.
                Button {
                    NSWorkspace.shared.open(AppInfo.repositoryURL)
                } label: {
                    // Same verified gold + black pairing `StatusBadge` already uses
                    // (`Color.outdatedIcon`'s own doc comment) — not a second, untracked
                    // yellow that a future recolor of the app's "needs attention" gold
                    // would silently miss.
                    Label(L("Star on GitHub"), systemImage: "star.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.outdatedIcon, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)

            LabeledContent(L("Developed by")) {
                HStack(spacing: 6) {
                    Link(AppInfo.developerName, destination: AppInfo.developerURL)
                    Text(verbatim: "·")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Link(destination: AppInfo.brandURL) {
                        Text(verbatim: AppInfo.brand)
                    }
                    .help(AppInfo.brandURL.host() ?? "")
                    .accessibilityLabel(Text(verbatim: AppInfo.brandSpoken))
                }
            }
            LabeledContent(L("App website")) {
                Link(AppInfo.websiteURL.host() ?? "", destination: AppInfo.websiteURL)
            }
        }
    }
}

// MARK: - Reset

/// Last and on its own: the one action on this page that can't be undone.
private struct ResetDataSettings: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showingResetConfirmation = false

    var body: some View {
        // A settings row (label + explanation on the left, action on the right) — not a
        // centered standalone button, which read as the screen's primary call to action
        // rather than an infrequent, destructive one.
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Reset all data"))
                    Text(L("Clears all settings, history, and cached data stored by BrewMenu."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // The only destructive action in the app that skipped confirmation —
                // every other one (uninstall, cleanup, autoremove) asks first, and
                // this one is the most destructive of all: it wipes settings, history,
                // and cache irreversibly on a single click.
                Button(L("Reset…"), role: .destructive) {
                    showingResetConfirmation = true
                }
                .confirmationDialog(
                    L("Reset all BrewMenu data?"),
                    isPresented: $showingResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(L("Reset"), role: .destructive) {
                        Task { await viewModel.resetAllData() }
                    }
                    Button(L("Cancel"), role: .cancel) {}
                } message: {
                    Text(
                        L(
                            "This clears all settings, history, and cached data stored by BrewMenu. This can't be undone."
                        )
                    )
                }
            }
        }
    }
}
