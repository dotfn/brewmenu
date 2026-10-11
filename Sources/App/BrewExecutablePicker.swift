import AppKit
import BrewCore

/// Lets the user point BrewMenu at a `brew` executable by picking it in Finder,
/// instead of typing an absolute filesystem path by hand — a non-technical user
/// doesn't know what `/opt/homebrew/bin/brew` means or how to type it correctly.
/// Used by both Onboarding and Settings, the two places that ask for a custom
/// Homebrew path.
@MainActor
enum BrewExecutablePicker {
    static func pick() -> String? {
        let panel = NSOpenPanel()
        panel.title = L("Select the brew executable")
        panel.message = L("Choose the \"brew\" file, usually inside a \"bin\" folder.")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        // Starts somewhere plausible; harmless if it doesn't exist — NSOpenPanel
        // just falls back to its own default location.
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
