import BrewCore
import SwiftUI

/// A button label for an action that runs a while ("Check Again" → "Checking…"). Idle shows its
/// symbol and title; busy puts a spinner in the symbol's place and the busy title in the title's.
///
/// Both are always laid out, the one not showing just invisible, so the button is as wide as the
/// wider of the two in both states. Swapping the title for a bare spinner shrank the button when a
/// run started and grew it back when it ended — a jump in the toolbar both times.
struct BusyButtonLabel: View {
    let title: String
    let busyTitle: String
    let systemImage: String
    let isBusy: Bool

    var body: some View {
        ZStack {
            content(Image(systemName: systemImage), title)
                .opacity(isBusy ? 0 : 1)
                .accessibilityHidden(isBusy)
            content(ProgressView().controlSize(.small), busyTitle)
                .opacity(isBusy ? 1 : 0)
                .accessibilityHidden(!isBusy)
        }
        .animation(.easeInOut(duration: 0.15), value: isBusy)
    }

    private func content(_ glyph: some View, _ text: String) -> some View {
        HStack(spacing: 6) {
            // One fixed slot for the symbol and the spinner, so the title starts at the same place.
            glyph.frame(width: 16, height: 16)
            Text(text)
        }
    }
}

/// The scrollable, color-coded raw log behind a command sheet's "Show more" — the
/// actual terminal-style output, auto-following the newest line while it's open.
/// Red for a failed line, orange for a warning, green for success: the same
/// convention `StatusBadge`/`InstalledPackageRow` already use for those states.
struct CommandLogDetail: View {
    let lines: [String]

    /// As tall as its lines, up to `maxHeight`, then it scrolls. A fixed height left a run's first
    /// three lines floating at the top of an empty box.
    static func height(forLines count: Int, maxHeight: CGFloat = 260) -> CGFloat {
        min(maxHeight, max(56, CGFloat(count) * 15 + 20))
    }

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

/// One line saying where a brew run stands (see `CommandRunMonitor.Snapshot.note`), where there's no
/// room for a bar: Clean Up and the rest in the popover, a doctor fix on its card (the sheets use
/// `CommandRunProgress`). A run gone quiet says so with a caution sign; the full sentence is in the
/// tooltip and what VoiceOver reads.
struct CommandRunStatusLine: View {
    let snapshot: CommandRunMonitor.Snapshot

    var body: some View {
        HStack(spacing: 6) {
            if snapshot.quietFor != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.outdatedIcon)
                    .accessibilityHidden(true)
            }
            Text(verbatim: snapshot.note)
                .foregroundStyle(snapshot.quietFor == nil ? Color.secondary : Color.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption)
        .help(snapshot.quietExplanation ?? snapshot.note)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: snapshot.quietExplanation ?? snapshot.note))
    }
}

/// A command sheet's progress while brew runs: a bar — brew's own percentage when it printed one,
/// moving stripes when it didn't — over what it's doing and how long it has taken. One line, not
/// the step, the figure and brew's raw line each saying the same thing.
struct CommandRunProgress: View {
    let snapshot: CommandRunMonitor.Snapshot

    private var isQuiet: Bool {
        snapshot.quietFor != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let progress = snapshot.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .tint(isQuiet ? Color.outdatedIcon : BrewTheme.accent)
            .accessibilityHidden(true)

            HStack(spacing: 6) {
                if isQuiet {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.outdatedIcon)
                }
                Text(verbatim: snapshot.activity)
                    .foregroundStyle(isQuiet ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(verbatim: snapshot.elapsedText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .monospacedDigit()
        }
        .help(snapshot.quietExplanation ?? snapshot.note)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: snapshot.quietExplanation ?? snapshot.note))
        .accessibilityValue(snapshot.progress
            .map { Text($0.percentText) } ?? Text(""))
    }
}

/// The log behind a command sheet's "Show more": inset in its own box, as tall as what it holds.
struct CommandLogBox: View {
    let lines: [String]

    var body: some View {
        CommandLogDetail(lines: lines)
            .frame(height: CommandLogDetail.height(forLines: lines.count))
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: CardCornerRadius.small))
            .overlay(RoundedRectangle(cornerRadius: CardCornerRadius.small).strokeBorder(.separator))
            .padding([.horizontal, .bottom])
    }
}

/// A command sheet's icon: the package's own while brew works on one, the outcome's symbol
/// otherwise (done, failed, cancelled — or a run of several, which has no one icon).
struct CommandSheetIcon: View {
    let package: String?
    let symbol: String
    let tint: Color
    let store: BrewStore

    static let size: CGFloat = 32

    var body: some View {
        Group {
            if let package {
                let installed = store.installedPackage(named: package)
                let entry = catalogEntry(package, isCask: installed?.isCask ?? false, in: store)
                PackageIcon(
                    name: entry.name,
                    displayName: entry.displayName,
                    isCask: entry.isCask,
                    appPath: entry.appPath,
                    size: Self.size
                )
            } else {
                Image(systemName: symbol)
                    .font(.system(size: Self.size * 0.75))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: Self.size, height: Self.size)
        // The title next to it says the same, in words.
        .accessibilityHidden(true)
    }
}
