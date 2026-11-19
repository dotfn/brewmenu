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

    /// How long a cancelled command gets to exit after SIGTERM before SIGKILL.
    static let killGrace: DispatchTimeInterval = .seconds(2)

    func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> ProcessResult {
        // Both streams are drained as data arrives (see `launch`), never read only after exit:
        // that deadlocks once output exceeds the pipe's OS buffer (~64KB) — the child blocks
        // writing to a full pipe and never exits. `brew info --json=v2 --installed` routinely
        // returns hundreds of KB and hit exactly this.
        try await execute(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            stdout: .make(terminal: false),
            collector: OutputCollector(onLine: { _ in })
        )
    }

    func runStreaming(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        onLine: @escaping @Sendable (String) -> Void,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        // A pty for stdout, not a plain pipe — some subprocesses (`curl`, which is
        // what actually fetches every cask/bottle download `brew install` runs) check
        // whether stdout is a real terminal and, when it isn't, switch to `--silent`,
        // dropping their own progress meter entirely. That's exactly why a big cask
        // install used to look identical to a genuine hang: nothing was reaching this
        // pipe until the download finished. Presenting a pty makes that check pass
        // again so progress keeps flowing; falls back to a plain pipe (no progress,
        // but never fails an install over it) if the pty can't be created.
        try await execute(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            stdout: .make(terminal: true),
            collector: OutputCollector(onLine: onLine, onProgress: onProgress ?? { _ in })
        )
    }

    private func execute(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdout: StdoutChannel,
        collector: OutputCollector
    ) async throws -> ProcessResult {
        let child = ChildProcess()
        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation { continuation in
                Self.launch(
                    child,
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment,
                    stdout: stdout,
                    collector: collector,
                    continuation: continuation
                )
            }
            // Propagate Task cancellation even when the process exited cleanly after SIGTERM.
            try Task.checkCancellation()
            return result
        } onCancel: {
            // Only signals. The exit watcher in `launch` resolves the operation once the child
            // has really exited, so the gate in `BrewService` can't be released while brew still
            // holds Homebrew's lock.
            child.cancel()
        }
    }

    /// Spawns the command and resumes `continuation` exactly once: here if it never starts,
    /// otherwise from the exit watcher.
    private static func launch(
        _ child: ChildProcess,
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdout: StdoutChannel,
        collector: OutputCollector,
        continuation: CheckedContinuation<ProcessResult, Error>
    ) {
        let stderrPipe = Pipe()
        let stderrRead = stderrPipe.fileHandleForReading
        let stdoutDrained = DispatchSemaphore(value: 0)
        let stderrDrained = DispatchSemaphore(value: 0)

        guard !child.isCancelled else {
            stdout.closeAll()
            continuation.resume(throwing: CancellationError())
            return
        }
        do {
            let pid = try spawn(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                stdoutFD: stdout.childHandle.fileDescriptor,
                stderrFD: stderrPipe.fileHandleForWriting.fileDescriptor
            )
            // A cancellation that raced in while spawning is acted on here.
            child.didLaunch(pid)
        } catch {
            stdout.closeAll()
            continuation.resume(throwing: error)
            return
        }
        // The child holds its own copies of the write ends. Ours must close, or the read ends
        // never see EOF: a pty or pipe reports it only once *every* copy is closed.
        stdout.closeChildCopy()
        try? stderrPipe.fileHandleForWriting.close()

        // At EOF each handler stops itself and closes its own handle. Doing that from the exit
        // watcher below raced the handler: at EOF it keeps firing, and one call still inside
        // `availableData` when the watcher closed the pty raised NSFileHandleOperationException
        // (bad file descriptor) — an Objective-C exception, which Swift can't catch.
        stdout.readHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty else { return collector.appendStdout(data) }
            handle.readabilityHandler = nil
            stdout.closeReadHandle()
            stdoutDrained.signal()
        }
        stderrRead.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty else { return collector.appendStderr(data) }
            handle.readabilityHandler = nil
            // Closed before the drain is signalled, so it's closed by the time the command returns.
            try? handle.close()
            stderrDrained.signal()
            // The handler is what keeps the pipe alive until EOF (stdout's does the same through
            // `stdout`): released any earlier, it closes, and the child dies of SIGPIPE writing to it.
            withExtendedLifetime(stderrPipe) {}
        }

        DispatchQueue.global().async {
            let exitCode = child.waitForExit()
            // Output can still sit in the pipes when the process exits; reading the collector
            // right away would drop it. Wait for each stream to reach EOF — bounded, since a
            // grandchild that inherited the pipe keeps it open. In that case the handlers stay
            // until it lets go, and close then; anything they read by then is past the result.
            _ = stdoutDrained.wait(timeout: .now() + drainTimeout)
            _ = stderrDrained.wait(timeout: .now() + drainTimeout)
            // What a lingering grandchild writes from here on belongs to no result: not kept, and
            // not passed on.
            collector.seal()
            if child.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(returning: ProcessResult(
                    exitCode: exitCode,
                    stdout: collector.stdout,
                    stderr: collector.stderr
                ))
            }
        }
    }

    /// `posix_spawn` rather than `Process`, for the one thing `Process` can't do: start the child
    /// as the leader of its own process group (`POSIX_SPAWN_SETPGROUP`), so cancelling can signal
    /// brew *and* everything brew spawned.
    private static func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        stdoutFD: Int32,
        stderrFD: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // No stdin: brew must never wait on input nobody will type.
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrFD, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        // `CLOEXEC_DEFAULT` keeps every other descriptor of this app (other commands' pipes
        // and ptys among them) out of the child.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = ([executablePath] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executablePath, &actions, &attributes, argv, envp)
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .ENOEXEC) }
        return pid
    }
}

// MARK: - ChildProcess

/// The spawned command's pid, and the two things that race over it: cancellation (which signals
/// its process group) and its exit. A pid can be reused once the child has been reaped, so a
/// signal is only ever sent while the child is known not to have been.
private final class ChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var exited = false
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Call from `onCancel`, which can fire before the command has been spawned. In that case
    /// this only records it, and `launch` either skips the spawn or `didLaunch` stops the child.
    func cancel() {
        let launched = lock.withLock {
            cancelled = true
            return pid != nil
        }
        if launched { stopGroup() }
    }

    func didLaunch(_ pid: pid_t) {
        let cancelledMeanwhile = lock.withLock {
            self.pid = pid
            return cancelled
        }
        if cancelledMeanwhile { stopGroup() }
    }

    /// Blocks until the child exits and returns its exit code — or, like `Process`, the signal
    /// number if a signal ended it.
    func waitForExit() -> Int32 {
        guard let pid = lock.withLock({ pid }) else { return -1 }
        // Wait without reaping first: marking `exited` before the pid is released is what
        // keeps `signal` from ever reaching an unrelated process that reused it.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        lock.withLock { exited = true }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : signal
    }

    /// SIGTERM to the whole group, then SIGKILL for whatever ignored it.
    private func stopGroup() {
        signal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + SystemProcessRunner.killGrace) { [self] in
            signal(SIGKILL)
        }
    }

    private func signal(_ signal: Int32) {
        lock.withLock {
            guard let pid, !exited else { return }
            kill(-pid, signal)
        }
    }
}

// MARK: - StdoutChannel

/// A child process's stdout connection — either a real pseudo-terminal (so subprocesses that
/// only show progress on a real tty keep doing so) or a plain pipe.
private struct StdoutChannel {
    let childHandle: FileHandle
    let readHandle: FileHandle
    private let closeChild: @Sendable () -> Void
    private let closeRead: @Sendable () -> Void

    static func make(terminal: Bool) -> StdoutChannel {
        if terminal, let pty = PTYPair() {
            return StdoutChannel(
                childHandle: pty.slaveHandle,
                readHandle: pty.masterHandle,
                closeChild: pty.closeSlave,
                closeRead: pty.closeMaster
            )
        }
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        return StdoutChannel(
            childHandle: writeHandle,
            readHandle: readHandle,
            closeChild: { try? writeHandle.close() },
            // Explicitly, at EOF: left to the `Pipe` being released, it closed a moment after the
            // command had returned.
            closeRead: { try? readHandle.close() }
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
    /// Set once the command's result has been taken (see `seal()`).
    private var sealed = false

    init(onLine: @escaping @Sendable (String) -> Void, onProgress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onLine = onLine
        self.onProgress = onProgress
    }

    /// Stops taking output: what still arrives after the command's result was built (a grandchild
    /// holding the stream open past the drain timeout) is dropped instead of piling up.
    func seal() {
        lock.withLock { sealed = true }
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
            guard !sealed else { return }
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
