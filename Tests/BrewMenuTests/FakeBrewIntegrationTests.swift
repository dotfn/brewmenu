@testable import BrewMenu
import Foundation
import Testing

/// End-to-end through the real process layer, against a fake `brew` script. These cover what the
/// mocks can't: the subprocess, the pipes, streamed output, and cancelling a running command.
/// Suite-wide safety net, same reasoning as ProcessRunnerTests' two suites: this is real-process
/// code that has hung CI silently before (see ci.yml's comment) — bound every test here so a
/// repeat shows up as a fast, named failure instead of another unexplained 15-minute stall.
@Suite("BrewService contra un brew falso", .serialized, .timeLimit(.minutes(2)))
struct FakeBrewIntegrationTests {
    private static let outdated = """
    {
      "formulae": [{"name": "git", "installed_versions": ["2.39.0"], "current_version": "2.40.0", "pinned": false}],
      "casks": [{"name": "iterm2", "installed_versions": ["3.4.0"], "current_version": "3.5.0", "pinned": false}]
    }
    """

    private func service(for fake: FakeBrew) async throws -> BrewService {
        let resolver = EnvironmentResolver(fileSystem: DefaultFileSystemChecker())
        let service = BrewService(resolver: resolver)
        try await service.bootstrap(customBrewPath: fake.brewPath)
        return service
    }

    @Test("fetchOutdated lee la salida real del proceso")
    func outdatedFromRealProcess() async throws {
        let fake = try FakeBrew.make(outdatedJSON: Self.outdated)
        defer { fake.remove() }
        let packages = try await service(for: fake).fetchOutdated()
        #expect(Set(packages.map(\.name)) == ["git", "iterm2"])
    }

    @Test("runUpgradeAll transmite las líneas de salida en orden")
    func upgradeStreamsLinesInOrder() async throws {
        let fake = try FakeBrew.make(outdatedJSON: Self.outdated)
        defer { fake.remove() }
        let lines = LineCollector()
        try await service(for: fake).runUpgradeAll(names: ["wget", "git"]) { lines.add($0) }
        #expect(lines.values == ["==> Upgrading wget", "==> Upgrading git"])
    }

    /// Regression for the cancel race: once cancelled, the child must be gone before the gate is
    /// released, so the next command starts clean. The fake records its PID to check that.
    ///
    /// `.timeLimit` because `await slow.value` after `cancel()` has no bound of its own — see
    /// the identical reasoning on `cancelKillsGrandchildren` in `ProcessRunnerTests.swift`. This
    /// test goes through the same real-process cancellation path, just via `BrewService` and a
    /// real fake-`brew` script instead of a bare shell command.
    @Test("cancelar un upgrade largo mata el proceso antes de liberar el gate", .timeLimit(.minutes(1)))
    func cancelledUpgradeIsGoneAndGateIsFree() async throws {
        let fake = try FakeBrew.make(outdatedJSON: Self.outdated)
        defer { fake.remove() }
        let service = try await service(for: fake)

        let slow = Task { try await service.runUpgradeAll(names: ["slow"]) { _ in } }
        try await waitUntil { FileManager.default.fileExists(atPath: fake.pidFile.path) }
        let pid =
            try #require(pid_t(try String(contentsOf: fake.pidFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)))

        slow.cancel()
        _ = try? await slow.value

        #expect(kill(pid, 0) != 0, "el proceso de brew debe haber terminado antes de devolver el control")
        // The gate is free: a following command runs straight away instead of waiting on the dead one.
        let start = ContinuousClock.now
        _ = try await service.fetchOutdated()
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

/// Collects streamed lines from @Sendable callbacks.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [String] = []
    func add(_ line: String) {
        lock.withLock { values.append(line) }
    }
}
