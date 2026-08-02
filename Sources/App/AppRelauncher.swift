import AppKit

/// Relaunches BrewMenu after a self-upgrade — shared by the popover's and the
/// Dashboard's restart banners so the two copies of this logic can't drift apart.
enum AppRelauncher {
    @MainActor
    static func restart() {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        )
        NSApp.terminate(nil)
    }
}
