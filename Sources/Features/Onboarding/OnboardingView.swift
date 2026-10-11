import AppKit
import BrewCore
import SwiftUI

struct OnboardingView: View {
    @State private var viewModel: OnboardingViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: OnboardingViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            // A `ScrollView`, not a bare `.frame`: the brew-detection step's
            // "not found" content (explanation + install button + browse row)
            // is taller than the other two steps and taller in a longer
            // translation — this keeps every action reachable instead of
            // letting the fixed window height clip the bottom of the step.
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                stepDots
                Spacer()
                nextButton
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480, height: 460)
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
            OnboardingStepHeader(
                systemImage: "mug.fill",
                iconSize: 64,
                tint: .yellow,
                title: L("Welcome to BrewMenu"),
                titleFont: .title
            )
            VStack(alignment: .leading, spacing: 12) {
                Label { Text(L("Detect outdated packages in the background")) }
                    icon: { Image(systemName: "arrow.down.circle") }
                Label { Text(L("Warn you if something's wrong with your setup")) }
                    icon: { Image(systemName: "stethoscope") }
                Label { Text(L("Run upgrades with real-time progress")) }
                    icon: { Image(systemName: "bolt.circle") }
            }
            .font(.body)
        }
        .padding(32)
    }

    private var notificationsContent: some View {
        VStack(spacing: 20) {
            OnboardingStepHeader(
                systemImage: "bell.badge.fill",
                iconSize: 52,
                tint: .blue,
                title: L("Notifications"),
                titleFont: .title2
            )
            Text(
                L(
                    "BrewMenu can notify you when updates are available, when something needs your attention, or when an upgrade fails."
                )
            )
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
            .foregroundStyle(granted ? Color.successIcon : .secondary)
            .font(.callout)
        } else {
            Button(L("Request permission")) {
                Task { await viewModel.requestNotifications() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var brewDetectionContent: some View {
        VStack(spacing: 16) {
            OnboardingStepHeader(
                systemImage: "magnifyingglass.circle.fill",
                iconSize: 52,
                tint: .orange,
                title: L("Detecting Homebrew"),
                titleFont: .title2
            )
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
            Label { Text(verbatim: path) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.successIcon) }
                .font(.system(.callout, design: .monospaced))
        } else {
            brewNotFoundContent
        }
    }

    /// Homebrew wasn't found at either default install location. A non-technical
    /// user doesn't know what that means or how to fix it by typing a path, so
    /// this gives two concrete actions instead of a bare text field: install
    /// Homebrew (opens its official site — BrewMenu can't run that installer
    /// itself, it needs an admin password and Terminal confirmation), or browse
    /// to an existing `brew` if one actually is installed somewhere non-default.
    private var brewNotFoundContent: some View {
        VStack(spacing: 14) {
            Text(L("Homebrew isn't installed, or BrewMenu couldn't find it automatically."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            } label: {
                Label(L("Install Homebrew…"), systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 8) {
                Rectangle().fill(.separator).frame(height: 1)
                Text(L("or")).font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(.separator).frame(height: 1)
            }
            .frame(maxWidth: 200)

            VStack(spacing: 6) {
                Text(L("Already have Homebrew somewhere else?"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField(
                        text: $viewModel.customBrewPath,
                        prompt: Text(verbatim: "/opt/homebrew/bin/brew")
                    ) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 220)
                    Button(L("Browse…")) {
                        if let path = BrewExecutablePicker.pick() { viewModel.customBrewPath = path }
                    }
                    Button(L("Check again")) { Task { await viewModel.detectBrew() } }
                }
                if !viewModel.customPathIsValid {
                    Text(L("No executable file at this path."))
                        .font(.caption)
                        .foregroundStyle(Color.errorIcon)
                }
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
            .disabled(viewModel.isDetecting || !viewModel.customPathIsValid)
            .keyboardShortcut(.return)
        } else {
            Button(L("Next")) { viewModel.advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
        }
    }
}

/// Icon + title pairing at the top of each onboarding step — same two-line shape,
/// different symbol/size/tint/title font per step.
private struct OnboardingStepHeader: View {
    let systemImage: String
    let iconSize: CGFloat
    let tint: Color
    let title: String
    let titleFont: Font

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize))
            .foregroundStyle(tint)
        Text(title)
            .font(titleFont)
            .fontWeight(.bold)
    }
}
