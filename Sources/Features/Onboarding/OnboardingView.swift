import SwiftUI

struct OnboardingView: View {
    @State var viewModel: OnboardingViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                stepDots
                Spacer()
                nextButton
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480, height: 420)
        .onDisappear {
            Task { await viewModel.completeSkipped() }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch viewModel.step {
        case .welcome:
            welcomeContent
        case .notifications:
            notificationsContent
        case .brewDetection:
            brewDetectionContent
        }
    }

    private var welcomeContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "mug.fill")
                .font(.system(size: 64))
                .foregroundStyle(.yellow)
            Text("Bienvenido a BrewMenu")
                .font(.title)
                .fontWeight(.bold)
            VStack(alignment: .leading, spacing: 12) {
                Label("Detecta paquetes desactualizados en segundo plano", systemImage: "arrow.down.circle")
                Label("Avisa cuando brew doctor encuentra problemas", systemImage: "stethoscope")
                Label("Ejecutá upgrades con progreso en tiempo real", systemImage: "bolt.circle")
            }
            .font(.body)
        }
        .padding(32)
    }

    @ViewBuilder
    private var notificationsContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 52))
                .foregroundStyle(.blue)
            Text("Notificaciones")
                .font(.title2)
                .fontWeight(.bold)
            Text("BrewMenu puede avisarte cuando hay actualizaciones disponibles, cuando brew doctor detecta problemas o cuando un upgrade falla.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            notificationPermissionControl
        }
        .padding(32)
    }

    @ViewBuilder
    private var notificationPermissionControl: some View {
        if let granted = viewModel.notificationsGranted {
            Label(
                granted ? "Notificaciones habilitadas" : "Podés habilitarlas desde Ajustes del sistema",
                systemImage: granted ? "checkmark.circle.fill" : "bell.slash"
            )
            .foregroundStyle(granted ? .green : .secondary)
            .font(.callout)
        } else {
            Button("Pedir permiso") {
                Task { await viewModel.requestNotifications() }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var brewDetectionContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
            Text("Detectando Homebrew")
                .font(.title2)
                .fontWeight(.bold)
            brewPathStatus
        }
        .padding(32)
        .task { await viewModel.detectBrew() }
    }

    @ViewBuilder
    private var brewPathStatus: some View {
        if viewModel.isDetecting {
            ProgressView("Buscando brew…")
        } else if let path = viewModel.detectedBrewPath {
            Label(path, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(.callout, design: .monospaced))
        } else {
            VStack(spacing: 10) {
                Label("No encontrado en los paths por defecto", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField("/ruta/a/brew", text: $viewModel.customBrewPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    // MARK: - Footer

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingViewModel.Step.allCases, id: \.self) { s in
                Circle()
                    .fill(s == viewModel.step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }

    @ViewBuilder
    private var nextButton: some View {
        if viewModel.step == .brewDetection {
            Button("Comenzar") {
                Task {
                    await viewModel.complete()
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isDetecting)
            .keyboardShortcut(.return)
        } else {
            Button("Siguiente") { viewModel.advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
        }
    }
}
