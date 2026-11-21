import BrewCore
@testable import BrewMenu
import Foundation
import Testing

@Suite("UpgradeActivity — qué dice el popover de un upgrade")
@MainActor
struct UpgradeActivityTests {
    @Test(
        "la fase sale de la última línea de brew",
        arguments: [
            (nil, UpgradeActivity.Step.preparing),
            ("==> Upgrading 1 outdated package:", .preparing),
            ("==> Fetching downloads for: gh", .downloading),
            ("==> Downloading https://ghcr.io/v2/homebrew/core/gh/blobs/sha256:abc", .downloading),
            ("###########                47.5%", .downloading),
            ("==> Pouring gh--2.105.0.arm64_tahoe.bottle.tar.gz", .installing),
            ("🍺  /opt/homebrew/Cellar/gh/2.105.0: 213 files, 54.1MB", .installing),
            ("==> Running `brew cleanup gh`...", .cleaningUp),
            ("Disable this behaviour by setting HOMEBREW_NO_INSTALL_CLEANUP.", .working),
        ] as [(String?, UpgradeActivity.Step)]
    )
    func stepFromLastLine(line: String?, step: UpgradeActivity.Step) {
        #expect(UpgradeActivity.step(fromLastLine: line) == step)
    }

    @Test(
        "qué línea de brew dice que empieza un paquete",
        arguments: [
            ("==> Upgrading gh", "gh"),
            ("==> Upgrading cameroncooke/axe/axe", "cameroncooke/axe/axe"),
            ("==> Upgrading 30 outdated packages:", nil),
            ("==> Upgrading 1 outdated package:", nil),
            ("==> Upgrading 2 dependents of upgraded formulae:", nil),
            ("==> Upgrading gh dependency: libyaml (0.2.4 -> 0.2.5)", nil),
            ("  2.103.2 -> 2.105.0", nil),
            ("==> Pouring gh--2.105.0.arm64_tahoe.bottle.tar.gz", nil),
        ] as [(String, String?)]
    )
    func startedPackage(line: String, name: String?) {
        #expect(UpgradeActivity.startedPackage(fromLine: line) == name)
    }

    @Test("Upgrade All dice en qué paquete va y cuántos lleva, contado de la salida real de brew")
    func upgradeAllPosition() async throws {
        let service = MockBrewService()
        let names = ["gh", "jq", "wget"]
        await service.setFetchResponses([names.map {
            OutdatedPackage(name: $0, installedVersions: ["1.0"], currentVersion: "2.0", pinned: false)
        }])
        // What brew prints for a run part-way through its second package.
        await service.setUpgradeAllOutput([
            "==> Upgrading 3 outdated packages:",
            "gh 1.0 -> 2.0",
            "==> Upgrading gh",
            "  1.0 -> 2.0",
            "🍺  /opt/homebrew/Cellar/gh/2.0: 213 files, 54.1MB",
            "==> Upgrading jq",
            "  1.0 -> 2.0",
            "==> Upgrading jq dependency: oniguruma (6.9.9 -> 6.9.10)",
        ])
        await service.holdUpgrade()
        let vm = MenuBarViewModel(service: service)
        await vm.performBootstrap()

        vm.upgradeAll()
        try await waitUntil { vm.upgradeStartedPackages == ["gh", "jq"] }

        guard case let .running(_, _, _, _, _, position?, _) = vm.upgradeActivity(at: .now) else {
            Issue.record("expected a .running with a position, got \(vm.upgradeActivity(at: .now))")
            return
        }
        #expect(position == UpgradeActivity.Position(current: "jq", number: 2, total: 3))

        await service.releaseUpgrade()
        try await waitUntil { !vm.isRunningAnyUpgrade }
    }

    @Test("un solo paquete no dice '1 de 1': su fila ya dice cuál es")
    func singleUpgradeHasNoPosition() async throws {
        let service = MockBrewService()
        await service.holdUpgrade()
        let vm = MenuBarViewModel(service: service)

        vm.upgradePackage("gh")
        try await waitUntil { await service.upgradeCallCount == 1 }
        guard case let .running(_, _, _, _, _, position, _) = vm.upgradeActivity(at: .now) else {
            Issue.record("expected .running")
            return
        }
        #expect(position == nil)

        await service.releaseUpgrade()
        try await waitUntil { !vm.isRunningAnyUpgrade }
    }

    @Test("en marcha dice qué paquete, y tras un minuto sin salida avisa de que puede estar colgado")
    func runningThenQuiet() async throws {
        let service = MockBrewService()
        await service.holdUpgrade()
        let vm = MenuBarViewModel(service: service)

        vm.upgradePackage("gh")
        try await waitUntil { await service.upgradeCallCount == 1 }

        guard case let .running(targets, _, _, _, quietFor, _, _) = vm.upgradeActivity(at: .now) else {
            Issue.record("expected .running, got \(vm.upgradeActivity(at: .now))")
            return
        }
        #expect(targets == ["gh"])
        #expect(quietFor == nil)

        let aMinuteOn = Date().addingTimeInterval(UpgradeActivity.quietThreshold + 1)
        guard case let .running(_, _, _, elapsed, quiet?, _, _) = vm.upgradeActivity(at: aMinuteOn) else {
            Issue.record("expected a quiet .running, got \(vm.upgradeActivity(at: aMinuteOn))")
            return
        }
        #expect(quiet >= UpgradeActivity.quietThreshold)
        #expect(elapsed >= UpgradeActivity.quietThreshold)

        await service.releaseUpgrade()
        try await waitUntil { !vm.isRunningAnyUpgrade }
    }

    @Test("terminado se ve unos segundos y luego el pie vuelve a la normalidad")
    func doneThenIdle() async throws {
        let vm = MenuBarViewModel(service: MockBrewService())
        vm.upgradePackage("gh")
        try await waitUntil { !vm.isRunningAnyUpgrade }

        #expect(vm.upgradeActivity(at: .now) == .done(targets: ["gh"]))
        let later = Date().addingTimeInterval(UpgradeActivity.outcomeVisibleFor + 1)
        #expect(vm.upgradeActivity(at: later) == .idle)
    }

    @Test("un fallo se queda, marca su fila, se puede reintentar y se descarta")
    func failureStaysUntilDismissed() async throws {
        let service = MockBrewService()
        await service.setUpgradeError(BrewError.commandFailed(exitCode: 1, stderr: "Error: nope"))
        let vm = MenuBarViewModel(service: service)

        vm.upgradePackage("gh")
        try await waitUntil { !vm.isRunningAnyUpgrade }

        let much = Date().addingTimeInterval(3600)
        guard case let .failed(targets, wasAll, _) = vm.upgradeActivity(at: much) else {
            Issue.record("expected .failed an hour later, got \(vm.upgradeActivity(at: much))")
            return
        }
        #expect(targets == ["gh"])
        #expect(!wasAll)
        #expect(vm.upgradeFailure(forPackage: "gh") != nil)
        #expect(vm.upgradeFailure(forPackage: "wget") == nil)

        // Retry runs the same package again.
        await service.setUpgradeError(nil)
        #expect(vm.retryUpgrade())
        try await waitUntil { !vm.isRunningAnyUpgrade }
        #expect(await service.upgradeCallCount == 2)
        #expect(vm.upgradeActivity(at: .now) == .done(targets: ["gh"]))
    }

    @Test("descartar un fallo deja el pie como estaba, también en la fila")
    func dismissedFailureIsGone() async throws {
        let service = MockBrewService()
        await service.setUpgradeError(BrewError.commandFailed(exitCode: 1, stderr: "Error: nope"))
        let vm = MenuBarViewModel(service: service)
        vm.upgradePackage("gh")
        try await waitUntil { !vm.isRunningAnyUpgrade }

        vm.clearUpgradeFailure()

        #expect(vm.upgradeActivity(at: .now) == .idle)
        #expect(vm.upgradeFailure(forPackage: "gh") == nil)
    }

    @Test("la fase sale del proceso cuando la línea solo dice que brew trabaja", arguments: [
        (nil, BrewBusyWith.compiling, UpgradeActivity.Step.compiling),
        ("Disable this behaviour by setting HOMEBREW_NO_INSTALL_CLEANUP.", .unpacking, .unpacking),
        ("==> Pouring gh--2.105.0.arm64_tahoe.bottle.tar.gz", .compiling, .installing),
        (nil, nil, .preparing),
    ] as [(String?, BrewBusyWith?, UpgradeActivity.Step)])
    func stepFromProcess(line: String?, busy: BrewBusyWith?, step: UpgradeActivity.Step) {
        #expect(UpgradeActivity.step(fromLastLine: line, busyWith: busy) == step)
    }

    @Test("descarga creciendo o CPU en uso aplazan el aviso de cuelgue, y la fase y los bytes llegan al estado")
    func activityKeepsItFromLookingStuck() async throws {
        let service = MockBrewService()
        await service.holdUpgrade()
        let probe = ScriptedActivityProbe()
        let vm = MenuBarViewModel(service: service, activityProbe: probe)

        vm.upgradePackage("gh")
        try await waitUntil { await service.upgradeCallCount == 1 }
        // Silent brew, but curl is downloading: bytes grow and CPU climbs between samples.
        await probe.play([
            BrewActivitySample(downloadedBytes: 1_000_000, cpuTime: 0.1, busyWith: .downloading),
            BrewActivitySample(downloadedBytes: 23_400_000, cpuTime: 0.5, busyWith: .downloading),
        ])
        try await waitUntil(timeout: .seconds(5)) { vm.upgradeDownloadedBytes == 23_400_000 }

        let output = try #require(vm.upgradeLastOutputAt)
        let activity = try #require(vm.upgradeLastActivityAt)
        #expect(activity > output)
        // A minute after the last output, but not after the last sign of work: not quiet.
        let atOutputPlusThreshold = output.addingTimeInterval(UpgradeActivity.quietThreshold)
        guard case let .running(_, step, _, _, quietFor, _, downloaded) = vm.upgradeActivity(at: atOutputPlusThreshold)
        else {
            Issue.record("expected .running")
            return
        }
        #expect(quietFor == nil)
        #expect(step == .downloading)
        #expect(downloaded == 23_400_000)

        await service.releaseUpgrade()
        try await waitUntil { !vm.isRunningAnyUpgrade }
    }

    @Test("el porcentaje que brew imprime llega al estado; el simulado, no")
    func realPercentOnly() async throws {
        let service = MockBrewService()
        await service.setUpgradeProgressOutput(["Downloading 5.3MB/11.5MB (46%)"])
        await service.holdUpgrade()
        let vm = MenuBarViewModel(service: service)

        vm.upgradePackage("gh")
        try await waitUntil { vm.upgradeLog.last == "Downloading 5.3MB/11.5MB (46%)" }
        guard case let .running(_, step, progress, _, _, _, _) = vm.upgradeActivity(at: .now) else {
            Issue.record("expected .running")
            return
        }
        #expect(step == .downloading)
        #expect(progress == 0.46)

        await service.releaseUpgrade()
        try await waitUntil { !vm.isRunningAnyUpgrade }
    }
}

/// Plays back samples one per call, then keeps returning the last.
actor ScriptedActivityProbe: BrewActivitySampling {
    private var samples: [BrewActivitySample] = []
    private var last = BrewActivitySample(downloadedBytes: 0, cpuTime: 0, busyWith: nil)

    func play(_ samples: [BrewActivitySample]) {
        self.samples = samples
    }

    func start(at _: Date) {}

    func sample() -> BrewActivitySample {
        if !samples.isEmpty { last = samples.removeFirst() }
        return last
    }
}
