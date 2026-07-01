import SwiftUI

struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    @State private var selectedTab: Tab = .general

    enum Tab { case general, notifications, about }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text(L("General")).tag(Tab.general)
                Text(L("Notifications")).tag(Tab.notifications)
                Text(L("About")).tag(Tab.about)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 420, height: 430)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await viewModel.load() }
        .onChange(of: viewModel.settings) { _, _ in
            Task { await viewModel.save() }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            GeneralTab(viewModel: viewModel)
        case .notifications:
            NotificationsTab(viewModel: viewModel)
        case .about:
            AboutTab()
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section(L("General")) {
                Toggle(L("Open at login"), isOn: $viewModel.settings.launchAtLogin)
                Toggle(L("Show update count"), isOn: $viewModel.settings.showUpdateBadge)

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
                        }.buttonStyle(.borderless)
                    }
                }
            } header: {
                Text(L("Homebrew path"))
            } footer: {
                Text(L("Leave empty to use the default path."))
            }

            Section {
                HStack {
                    Spacer()
                    Button(L("Reset all data…"), role: .destructive) {
                        Task { await viewModel.resetAllData() }
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
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

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "mug.fill")
                .font(.system(size: 56))
                .foregroundStyle(.yellow)

            VStack(spacing: 4) {
                Text(verbatim: "BrewMenu")
                    .font(.title2)
                    .fontWeight(.bold)
                Text(L("Homebrew health monitor for macOS"))
                    .foregroundStyle(.secondary)
                Text(L("Version \(appVersion)"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .padding(.horizontal, 60)

            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(L("Developed by"))
                        .foregroundStyle(.secondary)
                    Link("Nicolas Jimenez", destination: URL(string: "https://github.com/dotfn")!)
                }

                HStack(spacing: 4) {
                    Text(L("App website"))
                        .foregroundStyle(.secondary)
                    Text(L("Coming soon"))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
