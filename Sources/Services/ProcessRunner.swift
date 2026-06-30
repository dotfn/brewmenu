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
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { p in
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                continuation.resume(returning: ProcessResult(
                    exitCode: p.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
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

        return try await withTaskCancellationHandler {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.appendStdout(handle.availableData)
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.appendStderr(handle.availableData)
                }
                process.terminationHandler = { p in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: ProcessResult(
                        exitCode: p.terminationStatus,
                        stdout: collector.stdout,
                        stderr: collector.stderr
                    ))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            // Propagate Task cancellation even when process exits cleanly after terminate().
            try Task.checkCancellation()
            return result
        } onCancel: {
            process.terminate()
        }
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
