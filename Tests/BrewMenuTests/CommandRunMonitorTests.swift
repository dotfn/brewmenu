import BrewCore
@testable import BrewMenu
import Foundation
import SwiftUI
import Testing

@Suite("CommandRunMonitor — dónde está una ejecución de brew", .serialized)
@MainActor
struct CommandRunMonitorTests {
    @Test("dice en qué paquete va y cuántos lleva, y avisa tras un minuto sin señales de trabajo")
    func positionAndQuiet() {
        let monitor = CommandRunMonitor()
        let start = Date()
        monitor.begin(targets: ["gh", "jq", "wget"], at: start)
        #expect(monitor.position == nil, "no package started yet")

        monitor.started("gh")
        monitor.noteOutput(line: "==> Upgrading jq", at: start.addingTimeInterval(5))
        #expect(monitor.position == UpgradeActivity.Position(current: "jq", number: 2, total: 3))

        let calm = monitor.snapshot(at: start.addingTimeInterval(30), lastLine: "==> Upgrading jq")
        #expect(calm.quietFor == nil)
        #expect(calm.elapsed == 30)

        let quiet = monitor.snapshot(
            at: start.addingTimeInterval(5 + UpgradeActivity.quietThreshold + 1),
            lastLine: nil
        )
        #expect(quiet.quietFor != nil)
        #expect(quiet.quietExplanation != nil)
        #expect(quiet.note.hasPrefix(L("\(2) of \(3)")))
    }

    @Test("solo el porcentaje que brew imprime, y solo mientras descarga")
    func realPercentOnly() {
        let monitor = CommandRunMonitor()
        monitor.begin(targets: ["gh"])
        let downloading = monitor.snapshot(at: .now, lastLine: "Downloading 5.3MB/11.5MB (46%)")
        #expect(downloading.step == .downloading)
        #expect(downloading.progress == 0.46)
        let pouring = monitor.snapshot(at: .now, lastLine: "==> Pouring gh--2.105.0.arm64_tahoe.bottle.tar.gz")
        #expect(pouring.progress == nil)
    }

    @Test("esperando turno o releyendo el estado no cuenta como cuelgue")
    func waitingAndRefreshingAreNotQuiet() {
        let monitor = CommandRunMonitor()
        let start = Date()
        monitor.begin(targets: [], at: start)
        let later = start.addingTimeInterval(UpgradeActivity.quietThreshold * 3)

        let waiting = monitor.snapshot(at: later, lastLine: nil, waiting: true)
        #expect(waiting.step == .waiting)
        #expect(waiting.quietFor == nil)
        #expect(waiting.note.hasPrefix(L("Waiting for another Homebrew command…")))

        monitor.refreshing()
        let refreshing = monitor.snapshot(at: later, lastLine: "Removing: /opt/homebrew/Cellar/gh/2.0")
        #expect(refreshing.step == .refreshing)
        #expect(refreshing.quietFor == nil)
        #expect(refreshing.note.hasPrefix(L("Checking again…")))

        monitor.begin(targets: [], at: later)
        #expect(monitor.snapshot(at: later, lastLine: nil).step == .preparing, "a new run starts over")
    }

    @Test("junto a una barra: qué hace con los bytes de brew, y el tiempo aparte")
    func activityBesideABar() {
        let monitor = CommandRunMonitor()
        let start = Date()
        monitor.begin(targets: ["t3-code"], at: start)
        let run = monitor.snapshot(at: start.addingTimeInterval(9), lastLine: "Downloading 107.6MB/235.9MB (45%)")
        #expect(run.progress == 0.45)
        #expect(run.transfer == L("\("107.6 MB") of \("235.9 MB")"))
        #expect(run.activity == "\(L("Downloading")) · \(L("\("107.6 MB") of \("235.9 MB")"))")
        #expect(run.elapsedText == "0:09")
        #expect(!run.activity.contains("%"), "the bar shows the percentage")

        let installing = monitor.snapshot(at: start, lastLine: "==> Pouring t3-code--0.1.11.tar.gz")
        #expect(installing.transfer == nil)
        #expect(installing.activity == L("Installing…"))
        #expect(monitor.snapshot(at: start, lastLine: nil).activity == L("Preparing…"))
    }

    @Test("el log mide lo que tiene, hasta un tope")
    func logHeight() {
        #expect(CommandLogDetail.height(forLines: 3) < 80)
        #expect(CommandLogDetail.height(forLines: 500) == 260)
    }

    @Test("terminada, deja de estar en marcha")
    func ends() {
        let monitor = CommandRunMonitor()
        monitor.begin(targets: ["gh"])
        #expect(monitor.isRunning)
        monitor.end()
        #expect(!monitor.isRunning)
    }
}

@Suite("Hoja de instalación del Dashboard en marcha", .serialized)
@MainActor
struct InstallSheetRunTests {
    @Test("dice qué paquete instala y dónde está, en vez de un porcentaje simulado")
    func singleInstall() async throws {
        let service = MockBrewServiceForDashboard()
        await service.setInstallDelay(3_000_000_000)
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService())

        vm.installSingle(name: "wget", isCask: false)
        try await waitUntil { await service.installCalls.count == 1 }

        #expect(vm.installCurrentName == "wget")
        let run = try #require(vm.installRunSnapshot(at: .now))
        #expect(run.quietFor == nil)
        #expect(run.position == nil, "one package: no '1 of 1'")

        let hosted = HostedView(
            InstallLogView(dashboardViewModel: vm).environment(vm),
            size: CGSize(width: 520, height: 400)
        )
        defer { hosted.close() }
        try await hosted.settle()
        #expect(hosted.labels.contains(L("Installing \("wget")")), "labels: \(hosted.labels)")
        #expect(hosted.labels.contains { $0.hasPrefix("0:0") }, "the status line, its time: \(hosted.labels)")
        #expect(!hosted.labels.contains { $0.hasSuffix("%") }, "no simulated percentage: \(hosted.labels)")

        vm.cancelInstall()
        #expect(vm.installRunSnapshot(at: .now) == nil)
    }

    @Test("en una colección, el paquete en curso y cuántos lleva")
    func packPosition() async throws {
        let service = MockBrewServiceForDashboard()
        await service.setInstallDelay(3_000_000_000)
        let vm = DashboardViewModel(service: service, apiClient: MockHomebrewAPIService())
        let pack = InstallPack(
            id: "p",
            title: "P",
            subtitle: "",
            systemImage: "star",
            formulae: ["jq", "wget"],
            casks: []
        )

        vm.installPack(pack)
        try await waitUntil { await service.installCalls.count == 1 }

        #expect(vm.installCurrentName == "jq")
        #expect(vm.installRunSnapshot(at: .now)?.position == UpgradeActivity.Position(
            current: "jq",
            number: 1,
            total: 2
        ))
        vm.cancelInstall()
    }
}

@Suite("Clean Up, dependencias sin uso y arreglos de doctor en marcha", .serialized)
@MainActor
struct MaintenanceRunTests {
    @Test("Clean Up dice su etapa en vez de la última línea de brew, y desaparece al terminar")
    func cleanup() async throws {
        let service = MockBrewService()
        await service.setCleanupOutput(["Removing: /opt/homebrew/Cellar/gh/2.0... (200 files, 40MB)"])
        await service.setCleanupDelay(3_000_000_000)
        let vm = MenuBarViewModel(service: service)
        #expect(vm.cleanupSnapshot(at: .now) == nil)

        vm.cleanUp()
        try await waitUntil { vm.cleanupLog.count == 1 }

        let run = try #require(vm.cleanupSnapshot(at: .now))
        #expect(run.step == .cleaningUp)
        #expect(run.note.hasPrefix(L("Cleaning up…")))
        #expect(run.quietFor == nil)

        vm.cancelCleanUp()
        try await waitUntil { !vm.isCleaningUp }
        #expect(vm.cleanupSnapshot(at: .now) == nil)
    }

    @Test("quitar dependencias sin uso dice que está desinstalando")
    func autoremoveStep() {
        #expect(UpgradeActivity.step(fromLastLine: "==> Autoremoving 2 unneeded formulae:") == .uninstalling)
        #expect(UpgradeActivity
            .step(fromLastLine: "Uninstalling /opt/homebrew/Cellar/jq/1.7... (19 files)") == .uninstalling)
    }

    @Test("un arreglo de doctor: lo que hace brew, y después que vuelve a comprobar")
    func doctorFix() async throws {
        let service = MockBrewService()
        await service.setDoctorFixOutput(["==> Upgrading node"])
        await service.setHoldsDoctor(true)
        let vm = MenuBarViewModel(service: service)

        vm.runDoctorFix("brew upgrade node")
        try await waitUntil { await service.isDoctorHeld }

        #expect(vm.doctorFixLastLine == "==> Upgrading node", "brew's own line stays for the detail")
        let run = try #require(vm.doctorFixSnapshot(at: .now))
        #expect(run.step == .refreshing)
        #expect(run.quietFor == nil)

        await service.releaseDoctor()
        try await waitUntil { vm.runningDoctorFix == nil }
        #expect(vm.doctorFixSnapshot(at: .now) == nil)
    }
}

@Suite("Tarjeta de doctor con un arreglo en marcha", .serialized)
@MainActor
struct DoctorFixCardHostingTests {
    @Test("dice en qué está el arreglo y deja la última línea de brew debajo")
    func runningFix() async throws {
        let service = MockBrewService()
        await service.setDoctorFixOutput(["==> Upgrading node"])
        await service.setHoldsDoctor(true)
        let vm = MenuBarViewModel(service: service)
        let warning = DoctorWarning(severity: .warning, message: """
        Warning: Some installed formulae are outdated.
        Upgrade them with:
          brew upgrade node
        """)
        #expect(warning.commands == ["brew upgrade node"])

        vm.runDoctorFix("brew upgrade node")
        try await waitUntil { await service.isDoctorHeld }

        let card = DoctorWarningCard(warning: warning, onIgnore: {})
            .environment(DashboardNavigation())
            .environment(DashboardViewModel(
                service: MockBrewServiceForDashboard(),
                apiClient: MockHomebrewAPIService()
            ))
            .environment(vm)
        let hosted = HostedView(card, size: CGSize(width: 560, height: 320))
        defer { hosted.close() }
        try await hosted.settle()
        #expect(hosted.labels.contains { $0.hasPrefix(L("Checking again…")) }, "labels: \(hosted.labels)")
        #expect(hosted.labels.contains("==> Upgrading node"), "labels: \(hosted.labels)")

        await service.releaseDoctor()
        try await waitUntil { vm.runningDoctorFix == nil }
    }
}
