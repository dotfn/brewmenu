import Testing
@testable import BrewMenu

@Suite("StatusChecker")
struct StatusCheckerTests {

    // MARK: - Helpers

    private func makeChecker(
        service: MockBrewService,
        interval: StatusChecker.Interval = .hourly,
        onPackagesUpdated: @escaping @Sendable ([OutdatedPackage]) -> Void = { _ in },
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
        let checker = makeChecker(service: service, onPackagesUpdated: { received = $0 })

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
        let checker = makeChecker(service: service, onPackagesUpdated: { received = $0 })

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
}
