import BrewCore
import Darwin
import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var isSuccess: Bool {
        exitCode == 0
    }
}

protocol ProcessRunner: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult

    /// `onProgress` fires for carriage-return-delimited output — a terminal-style
    /// in-place update (a `curl`/download progress meter, say) rather than a
    /// completed line. Defaulted to `nil` so existing call sites are unaffected.
    func runStreaming(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult
}

extension ProcessRunner {
    func runStreaming(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        try await runStreaming(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            onLine: onLine,
            onProgress: nil
        )
    }
}

struct SystemProcessRunner: ProcessRunner {
    /// How long to wait for a stream to reach EOF after its process exits. Bounded
    /// because a grandchild (brew's own curl, ruby, installers) can inherit the pipe
    /// and keep it open after the direct child is gone.
    static let drainTimeout: DispatchTimeInterval = .seconds(2)

    /// Makes the child the leader of its own process group before it execs the real
    /// command, so cancellation can signal brew *and* everything brew spawned — a
    /// plain `terminate()` only reached the direct child and left its grandchildren
    /// (a half-finished download or installer) running. `/usr/bin/perl` is in the
    /// macOS base system and `setpgrp` + `exec` keep the pid, so `Process` still
    /// tracks the real command.
    private static let groupLeaderScript = "setpgrp(0, 0) or die \"setpgrp: $!\"; exec { $ARGV[0] } @ARGV or die \"exec: $!\""

    static func configureGroupLaunch(_ process: Process, executablePath: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", groupLeaderScript, executablePath] + arguments
    }

    /// How long a cancelled command gets to exit after SIGTERM before SIGKILL.
    static let killGrace: DispatchTimeInterval = .seconds(2)

    /// Stops the process group. Only called once the process has actually launched (see
    /// `LaunchGuard`). It does not resolve the operation: the termination handler does, once the
    /// child has really exited. So the gate in `BrewService` can't be released while brew still
    /// holds Homebrew's lock. SIGKILL is the fallback for a child that ignores SIGTERM.
    static func stopGroup(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
            if process.isRunning { kill(-pid, SIGKILL) }
        }
    }

    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult {
        let process = Process()
        Self.configureGroupLaunch(process, executablePath: executablePath, arguments: arguments)
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutDrained = DispatchSemaphore(value: 0)
        let stderrDrained = DispatchSemaphore(value: 0)

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
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                ProcessResult,
                Error
            >) in
                box.set(continuation)
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { stdoutDrained.signal() } else { collector.appendStdout(data) }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { stderrDrained.signal() } else { collector.appendStderr(data) }
                }

                process.terminationHandler = { p in
                    // Output can still sit in the pipes when the process exits; reading the
                    // collector right away would drop it. Wait for each stream to reach EOF —
                    // bounded, since a grandchild that inherited the pipe keeps it open.
                    DispatchQueue.global().async {
                        _ = stdoutDrained.wait(timeout: .now() + Self.drainTimeout)
                        _ = stderrDrained.wait(timeout: .now() + Self.drainTimeout)
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        if launchGuard.isCancelled {
                            box.resume(.failure(CancellationError()))
                            return
                        }
                        box.resume(.success(ProcessResult(
                            exitCode: p.terminationStatus,
                            stdout: collector.stdout,
                            stderr: collector.stderr
                        )))
                    }
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
                        Self.stopGroup(process)
                    }
                } catch {
                    box.resume(.failure(error))
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            if launchGuard.markCancelled() {
                Self.stopGroup(process)
                // The termination handler resolves this once the child has exited.
            }
        }
    }

    func runStreaming(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        let process = Process()
        Self.configureGroupLaunch(process, executablePath: executablePath, arguments: arguments)
        process.environment = environment

        // A pty for stdout, not a plain pipe — some subprocesses (`curl`, which is
        // what actually fetches every cask/bottle download `brew install` runs) check
        // whether stdout is a real terminal and, when it isn't, switch to `--silent`,
        // dropping their own progress meter entirely. That's exactly why a big cask
        // install used to look identical to a genuine hang: nothing was reaching this
        // pipe until the download finished. Presenting a pty makes that check pass
        // again so progress keeps flowing; falls back to a plain pipe (today's
        // behavior — no progress, but never fails an install over it) if the pty
        // can't be created.
        let stdoutChannel = StdoutChannel.make()
        process.standardOutput = stdoutChannel.childHandle
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stdoutDrained = DispatchSemaphore(value: 0)
        let stderrDrained = DispatchSemaphore(value: 0)

        // OutputCollector owns all mutable state and synchronizes with NSLock,
        // letting readabilityHandler and terminationHandler share it safely.
        let collector = OutputCollector(onLine: onLine, onProgress: onProgress ?? { _ in })

        let launchGuard = LaunchGuard()
        let box = ContinuationBox()
        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                ProcessResult,
                Error
            >) in
                box.set(continuation)
                stdoutChannel.readHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { stdoutDrained.signal() } else { collector.appendStdout(data) }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { stderrDrained.signal() } else { collector.appendStderr(data) }
                }
                process.terminationHandler = { p in
                    // Same drain-to-EOF as run(): don't resolve with output still in flight.
                    DispatchQueue.global().async {
                        _ = stdoutDrained.wait(timeout: .now() + Self.drainTimeout)
                        _ = stderrDrained.wait(timeout: .now() + Self.drainTimeout)
                        stdoutChannel.readHandle.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        stdoutChannel.closeReadHandle()
                        if launchGuard.isCancelled {
                            box.resume(.failure(CancellationError()))
                            return
                        }
                        box.resume(.success(ProcessResult(
                            exitCode: p.terminationStatus,
                            stdout: collector.stdout,
                            stderr: collector.stderr
                        )))
                    }
                }
                guard launchGuard.markLaunching() else {
                    stdoutChannel.closeAll()
                    box.resume(.failure(CancellationError()))
                    return
                }
                do {
                    try process.run()
                    // The child now holds its own copy of the write end (whether a pty
                    // slave or a pipe) — our copy must close so the read end eventually
                    // sees the child's own close/exit. `Pipe` does this for us
                    // automatically when handed to `Process` directly; a raw pty pair
                    // doesn't, so `StdoutChannel` always does it explicitly here.
                    stdoutChannel.closeChildCopy()
                    // See run()'s identical comment: confirming after the fact is what
                    // closes the race window between markLaunching() returning and
                    // process.run() actually starting the child.
                    if !launchGuard.confirmLaunched() {
                        Self.stopGroup(process)
                    }
                } catch {
                    stdoutChannel.closeAll()
                    box.resume(.failure(error))
                }
            }
            // Propagate Task cancellation even when process exits cleanly after terminate().
            try Task.checkCancellation()
            return result
        } onCancel: {
            if launchGuard.markCancelled() {
                Self.stopGroup(process)
                // The termination handler resolves this once the child has exited.
            }
        }
    }
}

// MARK: - StdoutChannel

/// A child process's stdout connection — either a real pseudo-terminal (preferred,
/// so subprocesses that only show progress on a real tty keep doing so) or a plain
/// pipe (fallback if the pty can't be created, matching the old, progress-less but
/// always-safe behavior).
private struct StdoutChannel {
    let childHandle: FileHandle
    let readHandle: FileHandle
    private let closeChild: @Sendable () -> Void
    private let closeRead: @Sendable () -> Void

    static func make() -> StdoutChannel {
        if let pty = PTYPair() {
            return StdoutChannel(
                childHandle: pty.slaveHandle,
                readHandle: pty.masterHandle,
                closeChild: pty.closeSlave,
                closeRead: pty.closeMaster
            )
        }
        let pipe = Pipe()
        return StdoutChannel(
            childHandle: pipe.fileHandleForWriting,
            readHandle: pipe.fileHandleForReading,
            closeChild: {}, // Process/Pipe already closes its own write-end copy.
            closeRead: {}
        )
    }

    func closeChildCopy() {
        closeChild()
    }

    func closeReadHandle() {
        closeRead()
    }

    func closeAll() {
        closeChild()
        closeRead()
    }
}

/// A pseudo-terminal pair. `openpty` is a native Darwin/POSIX call — no dependency
/// needed — but the two file descriptors it hands back need the same manual
/// close-exactly-once care a raw pipe would, since (unlike `Pipe`) `Process` has no
/// built-in knowledge of what a pty pair is or which end belongs to whom.
private final class PTYPair: @unchecked Sendable {
    let masterHandle: FileHandle
    let slaveHandle: FileHandle
    private let lock = NSLock()
    private var slaveClosed = false
    private var masterClosed = false

    init?() {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { return nil }
        // A freshly opened pty post-processes output like a real terminal by
        // default — `ONLCR` rewrites every `\n` the child writes into `\r\n`. That
        // silently broke line parsing: a real completed line (meant for `onLine`)
        // arrived as content+`\r` immediately followed by an empty `\n`-terminated
        // segment, so the `\r` half got misread as an in-place progress update and
        // the real line was never seen as one at all (confirmed against a live
        // `brew info` run — every line came through `onProgress`, none through
        // `onLine`). Turning `ONLCR` off makes the pty pass `\n` through unchanged,
        // like the plain pipe this replaces, while everything that actually makes a
        // pty useful here (`$stdout.tty?` being true) is unaffected.
        var attrs = termios()
        if tcgetattr(slaveFD, &attrs) == 0 {
            attrs.c_oflag &= ~UInt(ONLCR)
            tcsetattr(slaveFD, TCSANOW, &attrs)
        }
        masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)
        slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
    }

    /// Closes the parent's copy of the slave fd once the child has its own — without
    /// this, the master fd never sees output stop: a pty (like a pipe) only reports
    /// EOF once *every* copy of the write end is closed, and the child's copy alone
    /// isn't enough while the parent still holds this one open too.
    func closeSlave() {
        lock.withLock {
            guard !slaveClosed else { return }
            slaveClosed = true
            slaveHandle.closeFile()
        }
    }

    func closeMaster() {
        lock.withLock {
            guard !masterClosed else { return }
            masterClosed = true
            masterHandle.closeFile()
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

    /// Whether cancellation has been requested. Read by the termination handler, so a cancelled
    /// run is reported only once its child has exited.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
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

/// Thread-safe accumulator for process output. Parses both stdout and stderr into
/// lines for the callback.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void
    private let onProgress: @Sendable (String) -> Void
    private var _stdoutData = Data()
    private var _stderrData = Data()
    private var _stdoutLineBuffer = Data()
    /// curl (brew's own downloader) writes its progress meter to *stderr*, not
    /// stdout — confirmed against a real download — so this needs its own
    /// in-progress buffer distinct from stdout's, not a second consumer of the same
    /// one, or interleaved stdout/stderr reads would corrupt each other's partial line.
    private var _stderrLineBuffer = Data()

    init(onLine: @escaping @Sendable (String) -> Void, onProgress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onLine = onLine
        self.onProgress = onProgress
    }

    var stdout: String {
        lock.withLock { String(data: _stdoutData, encoding: .utf8) ?? "" }
    }

    var stderr: String {
        lock.withLock { String(data: _stderrData, encoding: .utf8) ?? "" }
    }

    /// A "line" for streaming purposes ends at `\n` (a real completed line) *or* `\r`
    /// (a terminal-style in-place update — a download progress meter, say, which
    /// never emits `\n` until the transfer is done). The two are reported through
    /// separate callbacks so a caller can append the former to a log and use the
    /// latter to drive a live progress indicator instead of spamming that log with
    /// one entry per repaint. stdout and stderr are both split this way and fed
    /// through the same two callbacks — a real terminal shows both interleaved too.
    func appendStdout(_ data: Data) {
        append(data, into: \._stdoutData, buffer: \._stdoutLineBuffer)
    }

    func appendStderr(_ data: Data) {
        append(data, into: \._stderrData, buffer: \._stderrLineBuffer)
    }

    private func append(
        _ data: Data,
        into dataKeyPath: ReferenceWritableKeyPath<OutputCollector, Data>,
        buffer bufferKeyPath: ReferenceWritableKeyPath<OutputCollector, Data>
    ) {
        guard !data.isEmpty else { return }
        var linesToEmit: [String] = []
        var progressToEmit: [String] = []
        lock.withLock {
            self[keyPath: dataKeyPath].append(data)
            self[keyPath: bufferKeyPath].append(data)
            // One pass over the buffer, keeping only the unfinished tail. Re-slicing it after
            // every line made a chunk with many lines quadratic.
            let buffer = self[keyPath: bufferKeyPath]
            var lineStart = buffer.startIndex
            var index = buffer.startIndex
            while index < buffer.endIndex {
                let byte = buffer[index]
                if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                    if let text = String(data: buffer[lineStart ..< index], encoding: .utf8), !text.isEmpty {
                        if byte == UInt8(ascii: "\n") { linesToEmit.append(text) } else { progressToEmit.append(text) }
                    }
                    lineStart = buffer.index(after: index)
                }
                index = buffer.index(after: index)
            }
            self[keyPath: bufferKeyPath] = Data(buffer[lineStart...])
        }
        // Emit outside the lock to avoid blocking I/O callbacks.
        linesToEmit.forEach { onLine($0) }
        progressToEmit.forEach { onProgress($0) }
    }
}
