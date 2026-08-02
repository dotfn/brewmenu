import Foundation

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var isSuccess: Bool { exitCode == 0 }
}

protocol ProcessRunner: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult

    func runStreaming(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult
}

struct SystemProcessRunner: ProcessRunner {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes as data arrives via readabilityHandler, set up before
        // `process.run()`. Waiting for terminationHandler and only then calling
        // readDataToEndOfFile() deadlocks once output exceeds the pipe's OS buffer
        // (~64KB): the child blocks writing to a full, undrained pipe, so it never
        // exits, so terminationHandler never fires. `brew info --json=v2 --installed`
        // routinely returns hundreds of KB and hit exactly this.
        let collector = OutputCollector(onLine: { _ in })

        let launchGuard = LaunchGuard()
        let box = ContinuationBox()
        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                box.set(continuation)
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.appendStdout(handle.availableData)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.appendStderr(handle.availableData)
                }

                process.terminationHandler = { p in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    box.resume(.success(ProcessResult(
                        exitCode: p.terminationStatus,
                        stdout: collector.stdout,
                        stderr: collector.stderr
                    )))
                }

                guard launchGuard.markLaunching() else {
                    box.resume(.failure(CancellationError()))
                    return
                }
                do {
                    try process.run()
                    // Only now — after `run()` has actually returned — does `launched`
                    // become visible to `onCancel`. A cancellation that raced in while
                    // `run()` itself was executing (markLaunching() already having
                    // returned true, but the process not actually started yet) is caught
                    // here instead, and it's this call site — never `onCancel` — that
                    // terminates a process guaranteed to have actually launched.
                    if !launchGuard.confirmLaunched() {
                        process.terminate()
                        box.resume(.failure(CancellationError()))
                    }
                } catch {
                    box.resume(.failure(error))
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            if launchGuard.markCancelled() {
                process.terminate()
                // Free the caller immediately instead of waiting for the child to
                // actually exit — a Ruby process (every `brew` invocation) doesn't
                // always act on SIGTERM right away, so waiting for `terminationHandler`
                // here could leave a cancelled caller (e.g. a view the user already
                // navigated away from) hanging for as long as the child takes to die.
                // The eventual `terminationHandler` call above still runs and cleans up
                // the pipes; `box` only lets the first of the two resumes win.
                box.resume(.failure(CancellationError()))
            }
        }
    }

    func runStreaming(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // OutputCollector owns all mutable state and synchronizes with NSLock,
        // letting readabilityHandler and terminationHandler share it safely.
        let collector = OutputCollector(onLine: onLine)

        let launchGuard = LaunchGuard()
        let box = ContinuationBox()
        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                box.set(continuation)
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.appendStdout(handle.availableData)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.appendStderr(handle.availableData)
                }
                process.terminationHandler = { p in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    box.resume(.success(ProcessResult(
                        exitCode: p.terminationStatus,
                        stdout: collector.stdout,
                        stderr: collector.stderr
                    )))
                }
                guard launchGuard.markLaunching() else {
                    box.resume(.failure(CancellationError()))
                    return
                }
                do {
                    try process.run()
                    // See run()'s identical comment: confirming after the fact is what
                    // closes the race window between markLaunching() returning and
                    // process.run() actually starting the child.
                    if !launchGuard.confirmLaunched() {
                        process.terminate()
                        box.resume(.failure(CancellationError()))
                    }
                } catch {
                    box.resume(.failure(error))
                }
            }
            // Propagate Task cancellation even when process exits cleanly after terminate().
            try Task.checkCancellation()
            return result
        } onCancel: {
            if launchGuard.markCancelled() {
                process.terminate()
                // Same reasoning as `run()`: don't block the cancelled caller on the
                // child actually dying.
                box.resume(.failure(CancellationError()))
            }
        }
    }
}

// MARK: - LaunchGuard

/// Coordinates a `Process`'s launch against `Task` cancellation so `terminate()`
/// is never called before `run()` has actually launched it. `withTaskCancellationHandler`'s
/// `onCancel` can fire concurrently with — even before — the operation closure that
/// calls `process.run()`; `NSTask.terminate()` on a not-yet-launched process throws
/// an Objective-C exception that Swift can't catch, crashing the process outright
/// (confirmed in production: `-[NSConcreteTask terminate]: task not launched`).
private final class LaunchGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var launched = false
    private var cancelled = false

    /// Call immediately before `process.run()`. Returns false if cancellation
    /// already arrived — the caller must skip launching entirely in that case.
    ///
    /// Deliberately does *not* set `launched` — flipping it here, before `run()`
    /// has actually executed, left a real (if narrow) window where `onCancel`,
    /// racing concurrently on another thread, could see `launched == true` and
    /// call `terminate()` on a `Process` that hadn't started yet. That's the exact
    /// crash this type exists to prevent, just with better odds. `confirmLaunched()`
    /// below closes that window by only publishing `launched` once `run()` is
    /// known to have actually returned.
    func markLaunching() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }

    /// Call immediately after `process.run()` returns successfully. Returns true
    /// unless a cancellation raced in while `run()` was executing — in that case
    /// the *caller* (never `onCancel`) is responsible for terminating the process,
    /// since only the caller can know `run()` has truly returned.
    func confirmLaunched() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        launched = true
        return !cancelled
    }

    /// Call from `onCancel`. Returns true if the caller should terminate the
    /// process now (it was already confirmed launched); false means either
    /// `markLaunching()` will see `cancelled` and skip launching, or `confirmLaunched()`
    /// will see it and terminate the process itself once `run()` returns.
    func markCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        return launched
    }
}

// MARK: - ContinuationBox

/// Resumes a `CheckedContinuation` exactly once, whichever of two competing sources —
/// the process's own `terminationHandler` finishing normally, or `onCancel` giving up
/// on it early — gets there first. A `CheckedContinuation` traps if resumed twice, and
/// without this, cancelling while `terminationHandler` is also mid-fire (or a slow-to-die
/// child eventually calling it after cancellation already resumed) would crash instead
/// of the second call harmlessly no-oping.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?

    func set(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ result: Result<ProcessResult, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        c.resume(with: result)
    }
}

// MARK: - OutputCollector

/// Thread-safe accumulator for process output. Parses stdout into lines for the callback.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void
    private var _stdoutData = Data()
    private var _stderrData = Data()
    private var _lineBuffer = Data()

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    var stdout: String { lock.withLock { String(data: _stdoutData, encoding: .utf8) ?? "" } }
    var stderr: String { lock.withLock { String(data: _stderrData, encoding: .utf8) ?? "" } }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        var linesToEmit: [String] = []
        lock.withLock {
            _stdoutData.append(data)
            _lineBuffer.append(data)
            while let idx = _lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let raw = _lineBuffer[_lineBuffer.startIndex..<idx]
                if let line = String(data: raw, encoding: .utf8), !line.isEmpty {
                    linesToEmit.append(line)
                }
                _lineBuffer = Data(_lineBuffer[_lineBuffer.index(after: idx)...])
            }
        }
        // Emit outside the lock to avoid blocking I/O callbacks.
        linesToEmit.forEach { onLine($0) }
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock { _stderrData.append(data) }
    }
}
