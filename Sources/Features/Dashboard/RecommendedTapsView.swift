import AppKit
import SwiftUI

struct RecommendedTapsView: View {
    let dashboardViewModel: DashboardViewModel

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 12)]

    var body: some View {
        // The ScrollView (not a VStack wrapping it and the error label as siblings)
        // is the single top-level view, with the error attached via `.safeAreaInset`
        // instead — same reasoning as InstalledView's SearchField: the scrollable
        // container needs to directly own the toolbar-adjacent edge for the native
        // titlebar separator to read consistently across sections.
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(dashboardViewModel.recommendedTaps) { tap in
                    RecommendedTapCard(tap: tap, dashboardViewModel: dashboardViewModel)
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .top) {
            if let error = dashboardViewModel.addTapError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
        .navigationSubtitle(dashboardViewModel.recommendedTaps.count == 1 ? L("1 tap") : L("\(dashboardViewModel.recommendedTaps.count) taps"))
    }
}

struct RecommendedTapCard: View {
    let tap: RecommendedTap
    let dashboardViewModel: DashboardViewModel

    private var isTapped: Bool { dashboardViewModel.isTapped(tap.tapName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: tap.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer()
                if let url = tap.repositoryURL {
                    // Icon-only — the tap name is already implied by the title below it;
                    // spelling it out again as underlined blue text just for this one
                    // link made the header read as a list of hyperlinks instead of a card.
                    // A small circular backing (not a bare glyph floating in the corner)
                    // gives it the same tappable-button weight as the chips below it.
                    Link(destination: url) {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(.secondary.opacity(0.15), in: Circle())
                    }
                    .pointerCursor()
                    .help(L("View \(tap.title) on GitHub (\(tap.tapName))"))
                }
            }
            Text(tap.title)
                .font(.headline)
            Text(tap.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Each package is its own clickable chip linking to its own project page
            // (not the tap repo — that just holds the formula definition, the real
            // project is usually hosted elsewhere), so the user can learn about each
            // one before deciding to add the tap. Chips instead of a list of underlined
            // links — the rounded-pill treatment (same one used for the Formula/Cask
            // tag in the Add sheet) reads as a tag, not a wall of hyperlinks.
            //
            // FlowLayout, not LazyVGrid: a grid lays out fixed-width *columns* sized to
            // the widest cell in that column across every row, which looks broken with
            // chips of very different lengths (short "vault" stranded far from "consul"
            // with a big gap, "1password-cli" wrapping mid-word). Flow packs each chip
            // left-to-right at its own natural width and only wraps when a row is full —
            // the actual "tag list" behavior this needed.
            FlowLayout(spacing: 6) {
                ForEach(tap.notablePackages) { package in
                    if let url = package.url {
                        Link(destination: url) {
                            packageChip(package.name)
                        }
                        .pointerCursor()
                        .help(L("Open \(package.name)'s page"))
                    } else {
                        packageChip(package.name)
                    }
                }
            }

            Spacer(minLength: 0)

            actionArea
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func packageChip(_ name: String) -> some View {
        HStack(spacing: 3) {
            Text(name)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(.tint.opacity(0.25), lineWidth: 0.5))
    }

    @ViewBuilder
    private var actionArea: some View {
        if isTapped {
            Label(L("Added"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if dashboardViewModel.isAddingTap {
            ProgressView().controlSize(.small)
        } else {
            Button(L("Add Tap")) {
                Task { await dashboardViewModel.addTap(tap.tapName) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel(L("Add \(tap.title) tap"))
        }
    }
}

/// Packs subviews left-to-right at their own natural size, wrapping to a new row once
/// a row runs out of width — the actual behavior a tag/chip list needs. `LazyVGrid`
/// looks close but lays out fixed-width *columns*, sized to the widest cell in that
/// column across every row, which reads as broken with unevenly-sized chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > maxWidth, origin.x > 0 {
                origin.x = 0
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, origin.x - spacing)
        }
        return CGSize(width: totalWidth, height: origin.y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = bounds.origin
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.maxX, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Pointer cursor

private extension View {
    /// `Link`'s custom-styled content (the repo icon button, the package chips) has no
    /// hover feedback of its own on macOS — without this, nothing about them signals
    /// "clickable" until the click itself.
    func pointerCursor() -> some View {
        onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
