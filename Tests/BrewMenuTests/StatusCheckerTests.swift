import Foundation
import Testing
@testable import BrewMenu

@Suite("StatusChecker")
struct StatusCheckerTests {

    // MARK: - Helpers

    private func makeChecker(
        service: MockBrewService,
        interval: StatusChecker.Interval = .hourly,
        onPackagesUpdated: @escaping @Sendable ([OutdatedPackage], Date) -> Void = { _, _ in },
        onError: @escaping @Sendable (Error) -> Void = { _ in }
    ) -> StatusChecker {
        StatusChecker(
            service: service,
            interval: interval,
            onPackagesUpdated: onPackagesUpdated,
            onError: onError
        )
    }

    // MARK: - performCheck

    @Test("performCheck sin paquetes llama onPackagesUpdated con array vacío")
    func checkWithNoPackagesCallsCallback() async {
        let service = MockBrewService()
        nonisolated(unsafe) var received: [OutdatedPackage]? = nil
        let checker = makeChecker(service: service, onPackagesUpdated: { packages, _ in received = packages })

        await checker.performCheck()

        #expect(received != nil)
        #expect(received?.isEmpty == true)
    }

    @Test("performCheck con paquetes llama onPackagesUpdated con los paquetes")
    func checkWithPackagesCallsCallback() async {
        let service = MockBrewService()
        let pkgs = [OutdatedPackage(name: "git", installedVersions: ["1.0"], currentVersion: "2.0", pinned: false)]
        await service.setFetchResponses([pkgs])
        nonisolated(unsafe) var received: [OutdatedPackage] = []
        let checker = makeChecker(service: service, onPackagesUpdated: { packages, _ in received = packages })

        await checker.performCheck()

        #expect(received.count == 1)
        #expect(received[0].name == "git")
    }

    @Test("performCheck con error llama onError")
    func checkWithErrorCallsErrorCallback() async {
        let service = MockBrewService()
        await service.setFetchError(BrewError.commandFailed(exitCode: 1, stderr: "fail"))
        nonisolated(unsafe) var gotError = false
        let checker = makeChecker(service: service, onError: { _ in gotError = true })

        await checker.performCheck()

        #expect(gotError)
    }

    // Regression: cleanup/autoremove dry-runs used to only refresh alongside
    // `brew doctor`, once every 24h — so the "Unused dependencies"/"Cleanup pending"
    // insights (and the sidebar badge/menu bar popover built from them) could sit
    // stale for most of a day, visibly disagreeing with a live check elsewhere in
    // the app (e.g. the Dashboard's own Unused Dependencies/Cache tools). They now
    // refresh on the same cadence as `fetchOutdated` — every `performCheck()`, not
    // gated behind the doctor interval.
    @Test("runCleanupDryRun/runAutoremoveDryRun se refrescan en cada performCheck(), no solo junto con brew doctor")
    func cleanupAndAutoremoveRefreshEveryCheckNotJustWithDoctor() async {
        let service = MockBrewService()
        let checker = makeChecker(service: service)

        await checker.performCheck()
        let doctorCallsAfterFirst = await service.doctorCallCount
        #expect(doctorCallsAfterFirst == 1)  // first check always runs doctor (lastDoctorRunAt starts nil)

        await checker.performCheck()

        // A second check, moments later, would NOT re-run doctor (24h hasn't passed) —
        // but the dry-runs should have refreshed both times regardless.
        #expect(await service.doctorCallCount == 1)
        #expect(await service.cleanupDryRunCallCount == 2)
        #expect(await service.autoremoveDryRunCallCount == 2)
    }

    // MARK: - Frecuencia de runUpdate

    @Test("Intervalo hourly: runUpdate se llama cada 6 chequeos")
    func hourlyIntervalUpdatesEvery6Checks() async {
        let service = MockBrewService()
        let checker = makeChecker(service: service, interval: .hourly)

        // 6 chequeos → 1 update (el chequeo 6)
        for _ in 1...6 { await checker.performCheck() }

        let updateCount = await service.updateCallCount
        let fetchCount = await service.fetchCallCount
        #expect(updateCount == 1)
        #expect(fetchCount == 6)
    }

    @Test("Intervalo hourly: runUpdate no se llama en los primeros 5 chequeos")
    func hourlyIntervalNoUpdateFirst5Checks() async {
        let service = MockBrewService()
        let checker = makeChecker(service: service, interval: .hourly)

        for _ in 1...5 { await checker.performCheck() }

        let updateCount = await service.updateCallCount
        #expect(updateCount == 0)
    }

    @Test("Intervalo sixHours: runUpdate se llama en cada chequeo")
    func sixHoursIntervalUpdatesEveryCheck() async {
        let service = MockBrewService()
        let checker = makeChecker(service: service, interval: .sixHours)

        for _ in 1...3 { await checker.performCheck() }

        let updateCount = await service.updateCallCount
        #expect(updateCount == 3)
    }

    @Test("Intervalo daily: runUpdate se llama en cada chequeo")
    func dailyIntervalUpdatesEveryCheck() async {
        let service = MockBrewService()
        let checker = makeChecker(service: service, interval: .daily)

        await checker.performCheck()
        await checker.performCheck()

        let updateCount = await service.updateCallCount
        #expect(updateCount == 2)
    }

    // MARK: - setInterval

    @Test("setInterval manual no inicia timer")
    func manualIntervalDoesNotSchedule() async {
        let service = MockBrewService()
        let checker = makeChecker(service: service, interval: .manual)

        await checker.start()
        await checker.stop()

        // Solo verificamos que no crashea y que el estado es coherente
        let fetchCount = await service.fetchCallCount
        #expect(fetchCount == 0)
    }

    // MARK: - startServicesPolling / stopServicesPolling

    @Test("startServicesPolling dispara un fetch inmediato de servicios")
    func startServicesPollingFetchesImmediately() async {
        let service = MockBrewService()
        let checker = makeChecker(service: service)

        await checker.startServicesPolling()
        await service.waitForFetchServicesCallCount(1)
        await checker.stopServicesPolling()

        let count = await service.fetchServicesCallCount
        #expect(count == 1)
    }

    @Test("startServicesPolling llamado dos veces no duplica el timer")
    func startServicesPollingIsIdempotent() async {
        let service = MockBrewService()
        let checker = makeChecker(service: service)

        // El guard de startServicesPolling corre sincrónicamente dentro del actor,
        // así que para cuando la segunda llamada se ejecuta, el timer ya quedó
        // asignado y no puede haberse disparado un segundo fetch inmediato.
        await checker.startServicesPolling()
        await checker.startServicesPolling()
        await service.waitForFetchServicesCallCount(1)
        await checker.stopServicesPolling()

        let count = await service.fetchServicesCallCount
        #expect(count == 1)
    }

    @Test("stopServicesPolling permite reiniciar el polling después")
    func stopServicesPollingAllowsRestart() async {
        let service = MockBrewService()
        let checker = makeChecker(service: service)

        await checker.startServicesPolling()
        await service.waitForFetchServicesCallCount(1)
        await checker.stopServicesPolling()

        await checker.startServicesPolling()
        await service.waitForFetchServicesCallCount(2)
        await checker.stopServicesPolling()

        let count = await service.fetchServicesCallCount
        #expect(count == 2)
    }

    @Test("start() no arranca el polling de servicios automáticamente")
    func startDoesNotBeginServicesPolling() async {
        let service = MockBrewService()
        let checker = makeChecker(service: service, interval: .manual)

        // start() con intervalo manual no agenda ningún timer (ni el principal ni el
        // de servicios), así que no hay nada async que esperar: si algún día empezara
        // a arrancar el polling de servicios, el guard de arriba lo detectaría igual.
        await checker.start()
        await checker.stop()

        let count = await service.fetchServicesCallCount
        #expect(count == 0)
    }
}
