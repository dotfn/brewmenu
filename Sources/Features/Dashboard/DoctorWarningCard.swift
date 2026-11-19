import AppKit
import BrewCore
import SwiftUI

/// One `brew doctor` finding on the Dashboard's Doctor page, whole: what's wrong, how to fix it
/// (brew's own words, with each command where brew puts it — runnable from here when it's a plain
/// `brew` command, copyable either way), the packages it's about, and where to read more. The
/// popover's `DoctorWarningRow` only shows the title and opens this page. Everything is
/// selectable — this is text people paste into Terminal or a bug report.
struct DoctorWarningCard: View {
    let warning: DoctorWarning
    /// Hides the finding from the icon, the popover and notifications (see
    /// `AppSettings.ignoredDoctorWarnings`) — for the ones that are known and accepted.
    let onIgnore: () -> Void
    @Environment(DashboardNavigation.self) private var navigation
    @Environment(DashboardViewModel.self) private var dashboardViewModel
    @Environment(MenuBarViewModel.self) private var viewModel
    /// The finding's own detail (a list of tools, of certificates) is reference, not the fix —
    /// collapsed so the fix stays near the title.
    @State private var showsDetail = false

    private var isError: Bool {
        warning.severity == .error
    }

    /// brew's steps, plus what BrewMenu knows applies (see `MenuBarViewModel.fixSteps(for:)`).
    private var fixSteps: [DoctorWarning.FixStep] {
        viewModel.fixSteps(for: warning)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isError ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isError ? Color.errorIcon : Color.outdatedIcon)
                .accessibilityLabel(isError ? L("Error") : L("Warning"))

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: warning.title)
                        .font(.headline)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // When brew's own fix isn't enough to go on.
                    AskAIMenu { AIPrompt.doctorFinding(warning) }
                    Button(L("Ignore"), action: onIgnore)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(L("Stop counting this warning in the menu bar and notifications"))
                        // Every card has one: the label says which finding.
                        .accessibilityLabel(L("Ignore \(warning.title)"))
                        .accessibilityInputLabels([L("Ignore")])
                }

                if !warning.affectedPackages.isEmpty {
                    affectedPackages
                }
                if !fixSteps.isEmpty {
                    fix
                }
                if warning.concernsPATH {
                    // Not `.secondary`: at caption size that's under 4.5:1, and this changes what
                    // the fix means.
                    Label(
                        L(
                            "BrewMenu runs Homebrew with its own environment, so PATH warnings here can differ from what Terminal reports."
                        ),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                }
                if let detail = warning.detail {
                    // A button, not a DisclosureGroup: inside a List row that drew as a plain
                    // "Details" with no disclosure triangle, which didn't look like it opened.
                    Button { showsDetail.toggle() } label: {
                        Label(
                            showsDetail ? L("Hide Details") : L("Show Details"),
                            systemImage: showsDetail ? "chevron.down" : "chevron.right"
                        )
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    if showsDetail {
                        Text(verbatim: detail)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Addresses the fix's text doesn't already show where it mentions them.
                ForEach(warning.links.filter { !fixSteps.contains(.link($0)) }, id: \.self) { url in
                    LearnMoreLink(url: url)
                }
            }
        }
        .padding(.vertical, 6)
        // With several findings, every card has its own "Copy command" and "Details": the container
        // says which finding they belong to.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(warning.title)
    }

    /// Opens each package's page, where it can be upgraded or removed.
    private var affectedPackages: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L("Affects:"))
                .font(.callout)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(warning.affectedPackages, id: \.self) { name in
                    Button(name) {
                        navigation.openPackage(dashboardViewModel.detailTarget(forPackageNamed: name))
                    }
                    .buttonStyle(.link)
                    .font(.system(.callout, design: .monospaced))
                    .accessibilityHint(L("Opens the package's page"))
                }
            }
        }
    }

    private var fix: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("How to fix"))
                .font(.subheadline.weight(.semibold))
            ForEach(Array(fixSteps.enumerated()), id: \.offset) { _, step in
                switch step {
                case let .text(text):
                    Text(Self.inlineCode(text))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case let .command(command):
                    DoctorCommandRow(command: command)
                case let .link(url):
                    LearnMoreLink(url: url)
                }
            }
        }
    }

    /// brew writes commands inline in backticks ("Run `brew doctor` afterwards"): shown as code,
    /// not as backticks. Inline syntax only, whitespace kept — the indented lists stay as they are.
    private static func inlineCode(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

private struct LearnMoreLink: View {
    let url: URL

    var body: some View {
        Link(L("Learn more (\(url.host() ?? url.absoluteString))"), destination: url)
            .font(.callout)
            .help(url.absoluteString)
    }
}

/// A finding the user ignored, on the Doctor page's Ignored list: its title, and the way back.
struct IgnoredDoctorWarningRow: View {
    let warning: DoctorWarning
    let onStopIgnoring: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: warning.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Stop Ignoring"), action: onStopIgnoring)
                .buttonStyle(.bordered)
                .controlSize(.small)
                // Several rows have this button: the label says which finding.
                .accessibilityLabel(L("Stop ignoring \(warning.title)"))
                .accessibilityInputLabels([L("Stop Ignoring")])
        }
    }
}

/// A command from brew's fix. A plain `brew` command of a kind BrewMenu runs anyway (upgrade,
/// reinstall, cleanup…) gets a Run button: it runs here, behind the same queue as every other brew
/// command, and the finding is checked again once it's done. The rest — `sudo`, shell profile edits
/// — are the user's call: Copy, or Copy and open Terminal, with a line saying why.
private struct DoctorCommandRow: View {
    let command: String
    @Environment(MenuBarViewModel.self) private var viewModel
    @State private var copied = false
    @State private var confirmingRun = false

    private var canRun: Bool {
        MenuBarViewModel.canRunDoctorFix(command)
    }

    private var isRunning: Bool {
        viewModel.runningDoctorFix == command
    }

    private var failure: String? {
        viewModel.doctorFixFailure.flatMap { $0.command == command ? $0.message : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isRunning {
                    Button(L("Cancel")) { viewModel.cancelDoctorFix() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if canRun {
                    Button(L("Run")) { confirmingRun = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        // One brew command at a time; another fix holds the queue.
                        .disabled(viewModel.runningDoctorFix != nil)
                        .accessibilityLabel(L("Run \(command)"))
                        .accessibilityInputLabels([L("Run")])
                }
                copyButton
                if !canRun {
                    Button(L("Copy & Open Terminal")) {
                        copy()
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: viewModel.doctorFixLastLine ?? L("Starting…"))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
            } else if let failure {
                InlineError(message: failure)
            } else if !canRun {
                Text(MenuBarViewModel.whyDoctorFixIsForTerminal(command))
                    .font(.caption)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: CardCornerRadius.small))
        .confirmationDialog(L("Run this command?"), isPresented: $confirmingRun, titleVisibility: .visible) {
            Button(L("Run")) { viewModel.runDoctorFix(command) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: "\(command)\n\n") + Text(L("BrewMenu runs it with Homebrew, then checks again."))
        }
        // "Copied" is feedback for the click, not a state: it goes back after a moment.
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
        // The command row is the only place this shows; say it.
        .onChange(of: failure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure).post() }
        }
    }

    private var copyButton: some View {
        Button(copied ? L("Copied") : L("Copy")) {
            copy()
            // VoiceOver doesn't reliably re-read a focused button whose title changed.
            AccessibilityNotification.Announcement(L("Copied")).post()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(copied ? L("Copied") : L("Copy command"))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
    }
}
