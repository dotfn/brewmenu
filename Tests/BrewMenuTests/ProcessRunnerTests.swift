import BrewCore
@testable import BrewMenu
import Foundation
import Testing

/// Regression coverage for a real production crash: `-[NSConcreteTask terminate]:
/// task not launched`. `withTaskCancellationHandler`'s `onCancel` can fire before
/// the operation closure ever calls `process.run()` — calling `Process.terminate()`
/// on a process that was never launched throws an Objective-C exception that
/// crashes the process outright (not a Swift `Error`, uncatchable via do/catch).
///
/// If a Task is already cancelled at the moment `withTaskCancellationHandler` is
/// called, Swift invokes `onCancel` synchronously, before the operation closure
/// runs — so cancelling before any `await` inside `run()`/`runStreaming()` reliably
/// reproduces the exact race that used to crash.
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
            try await runner.runStreaming(
                executablePath: "/bin/sleep",
                arguments: ["1"],
                environment: [:],
                onLine: { _ in }
            )
        }
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            // Same as above — reaching here without crashing is the assertion.
        }
    }

    // Regression: cancel used to resolve the caller at once, while the child could still be
    // running. BrewService's gate was then released, and the next brew command collided with
    // the one still holding Homebrew's lock. Now run() returns only after the child has exited,
    // even one that ignores SIGTERM (it gets SIGKILL after a short grace).
    @Test("run() cancelado no vuelve hasta que el proceso termina, aunque ignore SIGTERM", .timeLimit(.minutes(1)))
    func runCancelledReturnsOnlyAfterChildExits() async throws {
        let runner = SystemProcessRunner()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await runner.run(
                executablePath: "/bin/bash",
                arguments: ["-c", "trap '' TERM; echo $$ > '\(marker.path)'; sleep 30"],
                environment: [:]
            )
        }
        // Cancel only once the child has installed its trap (it writes its pid right after).
        try await waitUntil { (try? String(contentsOf: marker, encoding: .utf8))?.isEmpty == false }
        let pid =
            try #require(pid_t(try String(contentsOf: marker, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)))

        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            // Expected: a cancelled run reports cancellation.
        }

        #expect(kill(pid, 0) != 0, "the child must be gone by the time run() returns")
        #expect(Date().timeIntervalSince(start) < 6, "should stop after SIGTERM's grace, not wait for sleep 30")
    }
}

// Regression: output still sitting in the pipe when the child exits was dropped, so a
// large `brew info --json` could come back truncated and fail to parse.
// Suite-wide safety net: real subprocess + pty/pipe code has hung CI before (see
// ci.yml's comment) with zero diagnostic output — if that happens again, this turns
// a silent 15-minute job timeout into a fast, named "exceeded time limit" failure
// pointing at the actual test, instead of having to guess from wherever the log went
// quiet. 2 minutes is generous for anything here, which normally takes well under 1s.
@Suite("SystemProcessRunner — salida y cancelación de grupo", .timeLimit(.minutes(2)))
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
    //
    // `.timeLimit` for the same reason as `runCancelledReturnsOnlyAfterChildExits` above:
    // `await task.value` after `cancel()` has no bound of its own — if the cancellation
    // path's continuation (`ContinuationBox`/`LaunchGuard` in `ProcessRunner.swift`) ever
    // fails to resume (a process-group signal race that only a real OS scheduler can
    // trigger, seen twice in CI as a `swift test` run hanging for 6h and 34m — never
    // locally), this await blocks forever with no other backstop. A timed-out test here
    // fails loudly in under a minute instead of taking the whole CI job down with it.
    @Test("cancelar termina también los procesos que el comando lanzó", .timeLimit(.minutes(1)))
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
        let grandchild =
            try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)))

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
    func line(_ text: String) {
        lock.withLock { lines.append(text) }
    }

    func progressUpdate(_ text: String) {
        lock.withLock { progress.append(text) }
    }
}

@Suite("SystemProcessRunner — separación de líneas y progreso", .timeLimit(.minutes(2)))
struct StreamSplittingTests {
    /// `\n` ends a line; `\r` is an in-place progress update (a download meter). The
    /// parser was rewritten to scan once per chunk — this pins the split behaviour.
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
