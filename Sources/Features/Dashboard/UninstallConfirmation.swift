import BrewCore
import SwiftUI

extension View {
    /// The uninstall confirmation shared by every "remove this package" trash button
    /// in the app (Installed, every browse row's installed-state icon, Disk Usage).
    ///
    /// Heuristic safety check: `dependents` — other installed formulae that actually
    /// link against this one at runtime (`DashboardViewModel.installedDependents(of:)`)
    /// — names them and swaps the plain "you can reinstall it anytime" message for an
    /// explicit warning, with the primary button relabeled "Uninstall Anyway" so the
    /// extra risk is something the user actively clicks past, not just reads. This
    /// isn't a guarantee of breakage (Homebrew doesn't promise every linked dependency
    /// is still strictly required), but it's the same signal `brew uninstall` itself
    /// checks before refusing without `--force` — surfaced here instead of leaving the
    /// user to discover it from a wall of red CLI output after the fact.
    func uninstallConfirmation(
        isPresented: Binding<Bool>,
        name: String,
        dependents: [String],
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            L("Uninstall \(name)?"),
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(dependents.isEmpty ? L("Uninstall") : L("Uninstall Anyway"), role: .destructive) {
                onConfirm()
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            if dependents.isEmpty {
                Text(L("This removes \(name) from your Mac. You can reinstall it anytime."))
            } else {
                Text(L("\(name) is used by \(Self.formattedDependents(dependents)). Removing it may break them."))
            }
        }
    }

    /// Names first, capped so a package with many dependents stays readable in the
    /// dialog — same shape as the Upgrade All confirmation's package list.
    private static func formattedDependents(_ names: [String], cap: Int = 8) -> String {
        let shown = names.prefix(cap).joined(separator: ", ")
        let more = names.count - cap
        return more > 0 ? "\(shown) \(L("and \(more) more"))" : shown
    }
}
