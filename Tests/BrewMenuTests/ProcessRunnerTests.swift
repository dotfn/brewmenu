import Testing
import Foundation
@testable import BrewMenu

// Regression coverage for a real production crash: `-[NSConcreteTask terminate]:
// task not launched`. `withTaskCancellationHandler`'s `onCancel` can fire before
// the operation closure ever calls `process.run()` — calling `Process.terminate()`
// on a process that was never launched throws an Objective-C exception that
// crashes the process outright (not a Swift `Error`, uncatchable via do/catch).
//
// If a Task is already cancelled at the moment `withTaskCancellationHandler` is
// called, Swift invokes `onCancel` synchronously, before the operation closure
// runs — so cancelling before any `await` inside `run()`/`runStreaming()` reliably
// reproduces the exact race that used to crash.
struct ProcessRunnerTests {
    @Test("run() cancelado antes de lanzar el proceso no crashea")
    func runCancelledBeforeLaunchDoesNotCrash() async throws {
        let runner = SystemProcessRunner()
        let task = Task {
            try await runner.run(executablePath: "/bin/sleep", arguments: ["1"], environment: [:])
        }
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            // Either a CancellationError or a thrown launch error is fine — the
            // assertion that matters is that this line was ever reached.
        }
    }

    @Test("runStreaming() cancelado antes de lanzar el proceso no crashea")
    func runStreamingCancelledBeforeLaunchDoesNotCrash() async throws {
        let runner = SystemProcessRunner()
        let task = Task {
            try await runner.runStreaming(executablePath: "/bin/sleep", arguments: ["1"], environment: [:], onLine: { _ in })
        }
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            // Same as above — reaching here without crashing is the assertion.
        }
    }

    // Regression coverage for a UI report: navigating away from a view whose
    // `.task` was awaiting a slow `brew` call left the app looking "stuck" —
    // because `run()` used to wait for `terminationHandler` (i.e. the child
    // actually exiting) before returning, even after cancellation. A process
    // that traps SIGTERM (as some can) would keep the caller suspended for as
    // long as the child took to die instead of returning immediately.
    @Test("run() cancelado responde de inmediato aunque el proceso ignore SIGTERM", .timeLimit(.minutes(1)))
    func runCancelledReturnsImmediatelyEvenIfProcessIgnoresSIGTERM() async throws {
        let runner = SystemProcessRunner()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await runner.run(
                executablePath: "/bin/bash",
                arguments: ["-c", "trap '' TERM; touch '\(marker.path)'; sleep 5"],
                environment: [:]
            )
        }
        // Cancel only once the child has installed its trap (it touches the marker right
        // after), so this exercises the "already launched, ignores SIGTERM" path specifically.
        // Waiting on that signal instead of a fixed sleep keeps it deterministic under load.
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        task.cancel()

        let start = Date()
        do {
            _ = try await task.value
        } catch {
            // Expected — CancellationError.
        }
        let elapsed = Date().timeIntervalSince(start)

        // The trapped `sleep 5` won't actually exit for ~5 seconds; returning well
        // under that proves the caller isn't blocked on the child's real exit.
        #expect(elapsed < 2)
    }
}

// Regression: output still sitting in the pipe when the child exits was dropped, so a
// large `brew info --json` could come back truncated and fail to parse.
@Suite("SystemProcessRunner — salida y cancelación de grupo")
struct SystemProcessRunnerOutputTests {
    @Test("run() devuelve toda la salida aunque el proceso termine con datos aún en el pipe")
    func runKeepsAllOutputAtExit() async throws {
        let result = try await SystemProcessRunner().run(
            executablePath: "/bin/sh",
            arguments: ["-c", "head -c 3000000 /dev/zero | tr '\\0' a"],
            environment: ProcessInfo.processInfo.environment
        )
        #expect(result.stdout.count == 3_000_000)
    }

    // Regression: cancelling terminated only the direct child, so anything it had spawned
    // (brew's curl, ruby, installers) kept running after Cancel.
    @Test("cancelar termina también los procesos que el comando lanzó")
    func cancelKillsGrandchildren() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task {
            try await SystemProcessRunner().run(
                executablePath: "/bin/sh",
                arguments: ["-c", "sleep 60 & echo $! > '\(pidFile.path)'; wait"],
                environment: ProcessInfo.processInfo.environment
            )
        }
        try await waitUntil { (try? String(contentsOf: pidFile, encoding: .utf8))?.isEmpty == false }
        let grandchild = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!

        task.cancel()
        _ = try? await task.value

        try await waitUntil { kill(grandchild, 0) != 0 }
    }
}

/// Collects streamed output from the @Sendable callbacks.
private final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [String] = []
    private(set) var progress: [String] = []
    func line(_ text: String) { lock.withLock { lines.append(text) } }
    func progressUpdate(_ text: String) { lock.withLock { progress.append(text) } }
}

@Suite("SystemProcessRunner — separación de líneas y progreso")
struct StreamSplittingTests {
    // `\n` ends a line; `\r` is an in-place progress update (a download meter). The
    // parser was rewritten to scan once per chunk — this pins the split behaviour.
    @Test("\\n produce líneas y \\r produce progreso, en orden")
    func splitsLinesAndProgressInOrder() async throws {
        let capture = StreamCapture()
        _ = try await SystemProcessRunner().runStreaming(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'one\\ntwo\\r50%%\\rthree\\n'"],
            environment: ProcessInfo.processInfo.environment,
            onLine: { capture.line($0) },
            onProgress: { capture.progressUpdate($0) }
        )
        #expect(capture.lines == ["one", "three"])
        #expect(capture.progress == ["two", "50%"])
    }
}

