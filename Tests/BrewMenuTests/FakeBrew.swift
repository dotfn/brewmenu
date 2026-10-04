import Foundation

/// A `brew` stand-in: a shell script in a temporary folder that answers the commands BrewService
/// sends. Tests run it through the real `SystemProcessRunner`, so process groups, pipes and the
/// drain are exercised, not mocked. It can't stand in for the UI: nothing here clicks anything.
struct FakeBrew {
    let root: URL
    var brewPath: String {
        root.appendingPathComponent("bin/brew").path
    }

    var pidFile: URL {
        root.appendingPathComponent("slow.pid")
    }

    /// The script answers `shellenv`, `outdated`, `upgrade` and `upgrade slow`. `slow` sleeps for
    /// 30 seconds and records its PID, so a test can cancel it and check the process is gone.
    static func make(outdatedJSON: String) throws -> FakeBrew {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try outdatedJSON.write(to: root.appendingPathComponent("outdated.json"), atomically: true, encoding: .utf8)
        let script = """
        #!/bin/sh
        ROOT='\(root.path)'
        case "$1" in
          shellenv)
            echo "export HOMEBREW_PREFIX=\\"$ROOT\\";"
            echo "export HOMEBREW_CELLAR=\\"$ROOT/Cellar\\";"
            echo "export PATH=\\"$ROOT/bin:/usr/bin:/bin\\";"
            ;;
          outdated)
            cat "$ROOT/outdated.json"
            ;;
          upgrade)
            shift
            for name in "$@"; do
              if [ "$name" = "slow" ]; then
                echo $$ > "$ROOT/slow.pid"
                sleep 30
              fi
              echo "==> Upgrading $name"
            done
            ;;
          *)
            echo "fake brew: unsupported $1" >&2
            exit 2
            ;;
        esac
        """
        try script.write(to: bin.appendingPathComponent("brew"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bin.appendingPathComponent("brew").path
        )
        return FakeBrew(root: root)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
