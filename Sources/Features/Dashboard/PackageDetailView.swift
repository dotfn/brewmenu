import AppKit
import SwiftUI

struct PackageDetailView: View {
    let target: PackageDetailTarget
    let dashboardViewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    private var isInstalled: Bool { dashboardViewModel.isInstalled(target.name) }
    private var detail: PackageDetail? { dashboardViewModel.packageDetail }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if dashboardViewModel.isLoadingPackageDetail {
                LoadingView(fillHeight: true)
            } else if let detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if detail.deprecated || detail.disabled {
                            statusBanner(detail)
                        }

                        if let desc = detail.desc {
                            Text(desc)
                                .font(.body)
                        }

                        if let homepage = detail.homepage, let url = URL(string: homepage) {
                            Link(homepage, destination: url)
                                .font(.callout)
                        }

                        installCommandRow

                        infoGrid

                        if hasAnalytics {
                            analyticsSection
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Text(L("Couldn't load package info"))
                        .foregroundStyle(.secondary)
                    Button(L("Retry")) {
                        dashboardViewModel.selectPackage(name: target.name, isCask: target.isCask)
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Spacer()
                footerButton
            }
            .padding()
        }
        .frame(width: 460, height: 520)
        // `selectPackage` is already kicked off by whichever row's info button opened
        // this sheet (it sets `selectedPackageDetailTarget`, which is what triggers the
        // sheet's presentation) — calling it again here on appear used to fire a second,
        // redundant fetch for the same target. Since `selectPackage` only keeps the
        // *last* request's result, if that stray duplicate lost the race after a
        // successful first fetch, the sheet could flip from loaded content to "Couldn't
        // load package info" for no visible reason.
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: target.isCask ? "app.badge" : "terminal")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(verbatim: target.name)
                .font(.title2)
                .fontWeight(.bold)
                .lineLimit(1)
            Spacer()
            Button(L("Done")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Status banner

    private func statusBanner(_ detail: PackageDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                detail.disabled ? L("Disabled") : L("Deprecated"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.headline)
            .foregroundStyle(.orange)

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
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: CardCornerRadius.small))
    }

    // MARK: - Install command

    private var installCommandRow: some View {
        HStack {
            Text(verbatim: "$ \(detail?.installCommand ?? "")")
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            CopyButton(text: detail?.installCommand ?? "")
        }
        .padding(8)
        .cardBackground(CardCornerRadius.compact)
    }

    // MARK: - Info grid

    @ViewBuilder
    private var infoGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let version = detail?.version {
                infoRow(L("Current version"), version)
            }
            if let requirements = detail?.requirements, !requirements.isEmpty {
                infoRow(L("Requirements"), requirements.joined(separator: ", "))
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Analytics

    private var hasAnalytics: Bool {
        guard let detail else { return false }
        return detail.installs30d != nil || detail.installs90d != nil || detail.installs365d != nil
    }

    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L("Installs"))
            VStack(spacing: 0) {
                analyticsRow(L("Last 30 days"), detail?.installs30d)
                Divider()
                analyticsRow(L("Last 90 days"), detail?.installs90d)
                Divider()
                analyticsRow(L("Last 365 days"), detail?.installs365d)
            }
            .cardBackground(CardCornerRadius.small)
        }
    }

    private func analyticsRow(_ label: String, _ count: Int?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(count.map { "\($0)" } ?? "—")
                .fontWeight(.medium)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Footer action

    private var footerButton: some View {
        Group {
            if isInstalled {
                Label(L("Installed"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if dashboardViewModel.installingNames.contains(target.name) {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if dashboardViewModel.failedInstallNames.contains(target.name) {
                        // The real reason from brew, not a generic guess — see
                        // DashboardViewModel.installErrors.
                        Label(dashboardViewModel.installErrors[target.name] ?? L("Install failed"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                    }
                    Button(dashboardViewModel.failedInstallNames.contains(target.name) ? L("Try Again") : L("Install")) {
                        Task { await dashboardViewModel.install(name: target.name, isCask: target.isCask) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
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
        .foregroundStyle(copied ? .green : .primary)
        .help(L("Copy"))
        .accessibilityLabel(L("Copy"))
    }
}
