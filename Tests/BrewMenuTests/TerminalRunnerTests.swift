@testable import BrewMenu
import Foundation
import Synchronization
import Testing

/// `SystemProcessRunner.runStreaming` with a real child: the terminal brew gets, and what comes out
/// of brew's redrawn download block.
@Suite("SystemProcessRunner — brew en una terminal de verdad", .serialized)
struct TerminalRunnerTests {
    private final class Recorder: Sendable {
        let lines = Mutex<[String]>([])
        let progress = Mutex<[String]>([])
    }

    private var fixture: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/brew-fetch-deps-wget.pty").path
    }

    @Test("brew ve una terminal con tamaño y TERM, que es lo que necesita para dibujar sus descargas")
    func childSeesASizedTerminal() async throws {
        let recorder = Recorder()
        let result = try await SystemProcessRunner().runStreaming(
            executablePath: "/bin/sh",
            arguments: ["-c", "stty -f /dev/stdout size; echo \"$TERM\"; test -t 1 && echo tty"],
            environment: [:],
            onLine: { line in recorder.lines.withLock { $0.append(line) } },
            onProgress: nil
        )
        #expect(result.exitCode == 0)
        #expect(recorder.lines.withLock { $0 } == ["40 200", "xterm-256color", "tty"])
    }

    @Test("el bloque de descargas llega como líneas limpias y progreso real, y el resultado no lleva escapes")
    func downloadBlockThroughTheRunner() async throws {
        let recorder = Recorder()
        let result = try await SystemProcessRunner().runStreaming(
            executablePath: "/bin/cat",
            arguments: [fixture],
            environment: [:],
            onLine: { line in recorder.lines.withLock { $0.append(line) } },
            onProgress: { text in recorder.progress.withLock { $0.append(text) } }
        )
        let lines = recorder.lines.withLock { $0 }
        let progress = recorder.progress.withLock { $0 }

        #expect(result.exitCode == 0)
        #expect(lines.count == 21, "lines: \(lines)")
        #expect(lines.contains("✔︎ Bottle openssl@4 (4.1.0)"))
        #expect(progress.last.flatMap(CommandProgress.parsePercent(from:)) == 1, "progress: \(progress)")
        #expect(!result.stdout.contains("\u{1B}"))
        #expect(result.stdout.contains("✔︎ Bottle wget (1.25.0_2)\n"))
    }
}
