import BrewCore
import SwiftUI

/// The determinate progress bar shown while a brew command (install or upgrade) is
/// running — real `curl` percentage with a simulated fallback behind it when brew
/// reports none (see `CommandProgress`). Tinted with the app's brand accent: this
/// is exactly the kind of fully custom, app-drawn indicator BrewUI's design system
/// reserves amber for (see `BrewTheme`), not a system control.
struct CommandProgressBar: View {
    let progress: Double

    var body: some View {
        ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(BrewTheme.accent)
            // Curl reports in whole-percent jumps — animate the fill between them
            // so it reads as one continuous advance, not a stepladder.
            .animation(.linear(duration: 0.2), value: progress)
    }
}

/// The scrollable, color-coded raw log behind a command sheet's "Show more" — the
/// actual terminal-style output, auto-following the newest line while it's open.
/// Red for a failed line, orange for a warning, green for success: the same
/// convention `StatusBadge`/`InstalledPackageRow` already use for those states.
struct CommandLogDetail: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(verbatim: line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Self.color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
            }
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    static func color(for line: String) -> Color {
        if line.hasPrefix("✗") { return .red }
        if line.hasPrefix("⚠") { return .orange }
        if line.hasPrefix("✓") { return .green }
        return .primary
    }
}

/// The "Show more"/"Hide details" disclosure shared by every command log sheet —
/// collapsed by default (most runs just work; the raw output is noise until
/// something needs explaining), with a chevron that flips to show which state
/// a click will produce next.
struct CommandLogDisclosureButton: View {
    @Binding var showDetails: Bool

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(showDetails ? L("Hide details") : L("Show more"))
                Image(systemName: showDetails ? "chevron.up" : "chevron.down")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
