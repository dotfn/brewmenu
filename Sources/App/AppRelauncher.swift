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
        // (confirmed in production: "can't be opened, -609"). A detached helper that
        // polls for *this exact PID* to actually disappear — the same approach Sparkle's
        // own relauncher uses — waits on the real condition instead of guessing a fixed
        // delay; capped at 5s so a stuck teardown can't hang the relaunch forever.
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = [
            "-c",
            "for i in $(seq 1 50); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done; open -a '\(path)'",
        ]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
