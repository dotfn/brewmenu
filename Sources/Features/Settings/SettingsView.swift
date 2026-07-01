import SwiftUI

struct SettingsView: View {
    @State var viewModel: SettingsViewModel
    @State private var selectedTab: Tab = .general

    enum Tab { case general, notifications, about }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("General").tag(Tab.general)
                Text("Notificaciones").tag(Tab.notifications)
                Text("Acerca de").tag(Tab.about)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 420, height: 380)
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
            Section("General") {
                Toggle("Abrir al iniciar sesión", isOn: $viewModel.settings.launchAtLogin)

                Picker("Frecuencia de chequeo", selection: $viewModel.settings.checkInterval) {
                    ForEach(AppSettings.CheckInterval.allCases, id: \.self) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Resetear todos los datos…", role: .destructive) {
                        Task { await viewModel.resetAllData() }
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Notifications

private struct NotificationsTab: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Notificaciones") {
                Toggle("Nuevas actualizaciones disponibles", isOn: $viewModel.settings.notifyOnUpdates)
                Toggle("Fallo en upgrade", isOn: $viewModel.settings.notifyOnUpgradeFailure)
                Toggle("Nuevas advertencias de doctor", isOn: $viewModel.settings.notifyOnDoctorWarnings)
                Toggle("Insights críticos", isOn: $viewModel.settings.notifyOnCriticalInsights)
            }
        }
        .formStyle(.grouped)
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
                Text("BrewMenu")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Monitor de salud de Homebrew para macOS")
                    .foregroundStyle(.secondary)
                Text("Versión \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .padding(.horizontal, 60)

            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("Desarrollado por")
                        .foregroundStyle(.secondary)
                    Link("Nicolas Jimenez", destination: URL(string: "https://github.com/dotfn")!)
                }

                HStack(spacing: 4) {
                    Text("Sitio de la app")
                        .foregroundStyle(.secondary)
                    Text("Próximamente")
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
