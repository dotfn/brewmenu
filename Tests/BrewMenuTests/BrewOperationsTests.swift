@testable import BrewMenu
import Foundation
import Synchronization
import Testing

/// Holds every brew command until `release()`, so a second command really waits behind the first
/// — for as long as the test needs, not for a fixed sleep the first one could outlast under load.
final class HeldBrewRunner: ProcessRunner, Sendable {
    private let state = Mutex<(released: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    func release() {
        let waiting = state.withLock { state in
            state.released = true
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func run(executablePath _: String, arguments: [String],
             environment _: [String: String]) async throws -> ProcessResult
    {
        if arguments.contains("shellenv") {
            return ProcessResult(
                exitCode: 0,
                stdout: "export HOMEBREW_PREFIX=\"/opt/homebrew\";\nexport PATH=\"/usr/bin:/bin\";",
                stderr: ""
            )
        }
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                if !state.released { state.waiting.append(continuation) }
                return state.released
            }
            if resumeNow { continuation.resume() }
        }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func runStreaming(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        onLine _: @escaping @Sendable (String) -> Void,
        onProgress _: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        try await run(executablePath: executablePath, arguments: arguments, environment: environment)
    }
}

@Suite("BrewOperations — registro central")
@MainActor
struct BrewOperationsTests {
    @Test("una operación encolada pasa a en curso y luego desaparece")
    func lifecycle() {
        let log = BrewOperations()
        let id = UUID()
        log.enqueue(id: id, kind: .upgrade, subject: "wget")
        #expect(log.queued.map(\.subject) == ["wget"])
        #expect(log.running.isEmpty)

        log.start(id: id)
        #expect(log.running.map(\.subject) == ["wget"])
        #expect(log.queued.isEmpty)

        log.remove(id: id)
        #expect(log.operations.isEmpty)
    }

    /// The point of the log: while one command holds Homebrew's gate, the next one must show as
    /// queued, not vanish or run alongside it.
    @Test("con dos comandos concurrentes, uno corre y el otro espera, y el registro se vacía al final")
    func secondCommandShowsAsQueued() async throws {
        let log = BrewOperations()
        let resolver = EnvironmentResolver(fileSystem: MockFileSystem(executablePaths: ["/opt/homebrew/bin/brew"]))
        let runner = HeldBrewRunner()
        let service = BrewService(resolver: resolver, runner: runner, operations: log)
        try await service.bootstrap()

        let first = Task { try await service.runUpgrade("wget") }
        try await waitUntil { log.running.map(\.subject) == ["wget"] }
        let second = Task { try await service.runUpgrade("git") }
        try await waitUntil { log.queued.map(\.subject) == ["git"] }

        #expect(log.running.map(\.subject) == ["wget"])

        runner.release()
        try await first.value
        try await second.value
        try await waitUntil { log.operations.isEmpty }
    }
}

@Suite("MenuBarViewModel — espera tras la cola de brew")
@MainActor
struct MenuBarWaitingTests {
    @Test("isWaitingBehindBrew sigue al registro: verdadero con algo en cola, falso al empezar")
    func waitingFollowsTheLog() {
        let log = BrewOperations()
        let vm = MenuBarViewModel(service: MockBrewService(), operations: log)
        #expect(!vm.isWaitingBehindBrew)

        let id = UUID()
        log.enqueue(id: id, kind: .install, subject: "wget")
        #expect(vm.isWaitingBehindBrew)

        log.start(id: id)
        #expect(!vm.isWaitingBehindBrew)
    }
}
