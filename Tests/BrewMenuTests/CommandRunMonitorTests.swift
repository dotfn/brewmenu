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

        let hosted = HostedView(InstallLogView(dashboardViewModel: vm), size: CGSize(width: 520, height: 400))
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
