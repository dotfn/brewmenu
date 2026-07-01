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
            Text(L("Welcome to BrewMenu"))
                .font(.title)
                .fontWeight(.bold)
            VStack(alignment: .leading, spacing: 12) {
                Label { Text(L("Detect outdated packages in the background")) }
                    icon: { Image(systemName: "arrow.down.circle") }
                Label { Text(L("Alert when brew doctor finds problems")) }
                    icon: { Image(systemName: "stethoscope") }
                Label { Text(L("Run upgrades with real-time progress")) }
                    icon: { Image(systemName: "bolt.circle") }
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
            Text(L("Notifications"))
                .font(.title2)
                .fontWeight(.bold)
            Text(L("BrewMenu can notify you when updates are available, when brew doctor detects problems, or when an upgrade fails."))
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
            Label {
                Text(granted
                    ? L("Notifications enabled")
                    : L("You can enable them from System Settings"))
            } icon: {
                Image(systemName: granted ? "checkmark.circle.fill" : "bell.slash")
            }
            .foregroundStyle(granted ? .green : .secondary)
            .font(.callout)
        } else {
            Button(L("Request permission")) {
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
            Text(L("Detecting Homebrew"))
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
            ProgressView(L("Looking for brew…"))
        } else if let path = viewModel.detectedBrewPath {
            Label { Text(verbatim: path) } icon: { Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(.green)
                .font(.system(.callout, design: .monospaced))
        } else {
            VStack(spacing: 10) {
                Label { Text(L("Not found in default paths")) }
                    icon: { Image(systemName: "xmark.circle") }
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField("/path/to/brew", text: $viewModel.customBrewPath)
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
            Button(L("Get started")) {
                Task {
                    await viewModel.complete()
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isDetecting)
            .keyboardShortcut(.return)
        } else {
            Button(L("Next")) { viewModel.advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
        }
    }
}
