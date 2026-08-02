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
        let task = Task {
            try await runner.run(
                executablePath: "/bin/bash",
                arguments: ["-c", "trap '' TERM; sleep 5"],
                environment: [:]
            )
        }
        // Give the process a moment to actually launch and install its trap
        // before cancelling — this exercises the "already launched, ignores
        // SIGTERM" path specifically, distinct from the launch-race tests above.
        try await Task.sleep(nanoseconds: 200_000_000)
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
