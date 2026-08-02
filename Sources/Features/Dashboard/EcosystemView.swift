import AppKit
import SwiftUI

struct EcosystemView: View {
    let tap: Tap
    let dashboardViewModel: DashboardViewModel
    let navigation: DashboardNavigation

    private var packages: [InstalledPackage] {
        dashboardViewModel.packages(in: tap).sorted { $0.name < $1.name }
    }

    var body: some View {
        let packages = packages
        Group {
            if packages.isEmpty {
                ContentUnavailableView(L("No packages in this ecosystem"), systemImage: "cube.box")
            } else {
                List(packages) { pkg in
                    InstalledPackageRow(package: pkg, dashboardViewModel: dashboardViewModel)
                }
                .scrollContentBackground(.hidden)
            }
        }
        // The full tap identifier (e.g. "homebrew/core") plus the package count is
        // information, not an action — it belongs in the native subtitle slot under
        // the title, not stuffed into the toolbar as bare text.
        .navigationSubtitle("\(tap.name) — \(packages.count == 1 ? L("1 package") : L("\(packages.count) packages"))")
        .toolbar {
            // A third-party tap reached from the Ecosystems Overview has no
            // corresponding sidebar row to highlight (only official taps get their own
            // sidebar entry — third-party ones are grouped under "Third-Party"), so
            // there was no visible way back to where the user came from. This is
            // always available, not just for that case, since it's harmless either way.
            ToolbarItem(placement: .navigation) {
                Button {
                    navigation.selectedSection = .ecosystemsOverview
                } label: {
                    Label(L("Back to Ecosystems"), systemImage: "chevron.left")
                }
                .help(L("Back to Ecosystems"))
            }
            // ToolbarItemGroup, not a custom HStack+background in one ToolbarItem —
            // macOS already wraps *any* primaryAction content in its own rounded-pill
            // chrome, so a manually-added Capsule background rendered nested inside the
            // system's own one ("double background"). ToolbarItemGroup is Apple's actual
            // API for a set of controls that should read as one grouped, evenly-spaced
            // pill — this is what gives Finder's own toolbar groups their look, natively.
            ToolbarItemGroup(placement: .primaryAction) {
                if let url = tap.repositoryURL {
                    // A Button, not a Link — Link doesn't pick up the native toolbar
                    // button's monochrome tint or hover/press states in this context
                    // (same reasoning as AboutTab's "Star on GitHub" button), which is
                    // why this rendered as flat, dead-looking blue text.
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.forward")
                            .padding(.horizontal, 3)
                    }
                    .help(L("View on GitHub"))
                }
                if !tap.isOfficial {
                    if dashboardViewModel.removingTapNames.contains(tap.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        RemoveTapButton(tap: tap.name, dashboardViewModel: dashboardViewModel)
                    }
                }
            }
        }
    }
}

/// Monochrome at rest (matches every other toolbar icon), tints red on hover — a
/// destructive action doesn't need to shout by default, but should visibly warn once
/// the pointer is actually over it.
private struct RemoveTapButton: View {
    let tap: String
    let dashboardViewModel: DashboardViewModel
    @State private var isHovering = false

    var body: some View {
        Button(role: .destructive) {
            Task { await dashboardViewModel.removeTap(tap) }
        } label: {
            Image(systemName: "trash")
                .padding(.horizontal, 3)
                .foregroundStyle(isHovering ? .red : .primary)
        }
        .help(L("Remove Tap"))
        .onHover { isHovering = $0 }
    }
}
