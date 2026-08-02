import AppKit
import SwiftUI

// The old segmented-tab shell (SettingsView) is gone — General/Notifications/About
// are now sidebar destinations hosted directly by DashboardView. These three tab
// views are unchanged and reused verbatim.

// MARK: - General

struct GeneralTab: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            // No section header here — the window's navigationTitle already reads
            // "General" immediately above; repeating it as a section header too read
            // as a jarring duplicate label with nothing distinguishing the two.
            Section {
                Toggle(L("Open at login"), isOn: $viewModel.settings.launchAtLogin)
                Toggle(L("Show update count"), isOn: $viewModel.settings.showUpdateBadge)
                Toggle(L("Hide menu bar icon when nothing needs attention"), isOn: $viewModel.settings.hideMenuBarIconWhenClear)

                Picker(L("Check frequency"), selection: $viewModel.settings.checkInterval) {
                    ForEach(AppSettings.CheckInterval.allCases, id: \.self) { interval in
                        Text(verbatim: interval.displayName).tag(interval)
                    }
                }
            }

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
                Text(L("Leave empty to use the default path."))
            }

            // A settings row (label + explanation on the left, action on the right) —
            // not a centered standalone button, which read as the screen's primary call
            // to action rather than an infrequent, destructive one.
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
                        Text(L("This clears all settings, history, and cached data stored by BrewMenu. This can't be undone."))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
        // Toggles/pickers above save via DashboardView's .onChange(of: settings) →
        // settingsViewModel.save() — if that write fails (disk full, permissions), the
        // control had already flipped visually with nothing telling the user it didn't
        // actually persist. Surfaced here instead of silently discarded.
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

// MARK: - Notifications

struct NotificationsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section(L("Notifications")) {
                Toggle(L("Notify on new updates"), isOn: $viewModel.settings.notifyOnUpdates)
                Toggle(L("Notify on upgrade failure"), isOn: $viewModel.settings.notifyOnUpgradeFailure)
                Toggle(L("Notify on new doctor warnings"), isOn: $viewModel.settings.notifyOnDoctorWarnings)
                Toggle(L("Notify on critical insights"), isOn: $viewModel.settings.notifyOnCriticalInsights)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // The app's real icon, not a generic SF Symbol standing in for it — this is
            // the one screen in the app whose whole purpose is to say "this is what
            // you're running." Loaded directly from AppIcon.icns via AppBundle (same
            // resolver Localizable.strings/InstallPacks.json use) instead of
            // NSApp.applicationIconImage, which falls back to the generic Finder folder
            // icon when running unpackaged (`swift build`/Xcode's SPM scheme) since
            // there's no real .app bundle for macOS to resolve CFBundleIconFile from.
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)

            VStack(spacing: 6) {
                Text(verbatim: "BrewMenu")
                    .font(.title)
                    .fontWeight(.bold)
                Text(L("Homebrew health monitor for macOS"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // .primary, not .secondary — secondary text on the already-muted
                // quaternary pill background read as too low-contrast to comfortably see.
                Text(L("Version \(appVersion)"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .padding(.top, 4)
            }

            // A free, one-click way to support the project — placed right under the
            // version, the one thing everyone on this screen already has open, instead
            // of buried in the link list below where it'd read as just another fact.
            // A Button (not Link) so .buttonStyle actually applies — Link ignores it.
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/dotfn/brewmenu")!)
            } label: {
                Label(L("Star on GitHub"), systemImage: "star.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.yellow, in: Capsule())
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                AboutRow(systemImage: "person.fill", label: L("Developed by")) {
                    Link("Nicolas Jimenez", destination: URL(string: "https://github.com/dotfn")!)
                }
                Divider().padding(.leading, 38)
                AboutRow(systemImage: "globe", label: L("App website")) {
                    Link("brewmenu.vercel.app", destination: URL(string: "https://brewmenu.vercel.app/")!)
                }
            }
            .padding(.vertical, 2)
            .cardBackground()
            .frame(maxWidth: 320)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private var appIcon: NSImage {
        if let url = AppBundle.resources.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }
}

/// One labeled fact in the About card — icon + label on the leading side, the
/// actual value (a link, plain text, whatever fits) trailing, so "Developed by"
/// and "App website" read as the same kind of row instead of two hand-rolled HStacks.
private struct AboutRow<Value: View>: View {
    let systemImage: String
    let label: String
    @ViewBuilder let value: Value

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            value
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
