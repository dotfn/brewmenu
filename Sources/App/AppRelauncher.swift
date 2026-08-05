import AppKit

/// Relaunches BrewMenu after a self-upgrade — shared by the popover's and the
/// Dashboard's restart banners so the two copies of this logic can't drift apart.
enum AppRelauncher {
    @MainActor
    static func restart() {
        // `NSWorkspace.openApplication` only *starts* the launch and returns immediately —
        // calling `NSApp.terminate` right after raced it against this process's own
        // shutdown. Launch Services then saw a second instance of the same bundle ID
        // trying to start while the first was still tearing down and refused it
        // (confirmed in production: "can't be opened, -609"). A detached `open`, given a
        // moment to run after this process is actually gone, sidesteps the race entirely.
        let path = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.5; open -a '\(path)'"]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
