@testable import BrewMenu
import Foundation
import Testing

@Suite("LiveBrewActivityProbe — lo que brew hace sin decirlo", .serialized)
struct BrewActivityProbeTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("cuenta lo que crecen las descargas en curso, y no lo pierde cuando una termina")
    func downloadedBytes() async throws {
        let downloads = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: downloads) }
        // From an earlier run: not this one's.
        let old = downloads.appendingPathComponent("old--x.bottle.tar.gz.incomplete")
        try Data(count: 5000).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: old.path
        )

        let probe = LiveBrewActivityProbe(downloadsDirectory: downloads)
        await probe.start(at: Date(timeIntervalSinceNow: -1))

        let partial = downloads.appendingPathComponent("abc--gh--2.105.0.bottle.tar.gz.incomplete")
        try Data(count: 1000).write(to: partial)
        #expect(await probe.sample().downloadedBytes == 1000)

        try Data(count: 3000).write(to: partial)
        #expect(await probe.sample().downloadedBytes == 3000)

        // Done: Homebrew renames it. What it downloaded still counts.
        try FileManager.default.moveItem(
            at: partial,
            to: downloads.appendingPathComponent("abc--gh--2.105.0.bottle.tar.gz")
        )
        #expect(await probe.sample().downloadedBytes == 3000)
    }

    @Test("un log de compilación que crece cuenta como trabajo; uno de otra vez, no")
    func buildLogBytes() async throws {
        let logs = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: logs) }
        let package = logs.appendingPathComponent("gnutls", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let old = package.appendingPathComponent("01.configure")
        try Data(count: 800).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: old.path
        )

        let probe = LiveBrewActivityProbe(downloadsDirectory: try temporaryDirectory(), logsDirectory: logs)
        await probe.start(at: Date(timeIntervalSinceNow: -1))
        #expect(await probe.sample().buildLogBytes == 0)

        let make = package.appendingPathComponent("02.make")
        try Data(count: 2000).write(to: make)
        #expect(await probe.sample().buildLogBytes == 2000)
        try Data(count: 5000).write(to: make)
        #expect(await probe.sample().buildLogBytes == 5000)
    }

    @Test("ve los procesos que lanza la app y su CPU, sin permisos")
    func childProcessCPU() async throws {
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        busy.standardOutput = FileHandle.nullDevice
        try busy.run()
        defer { busy.terminate() }

        #expect(LiveBrewActivityProbe.descendants(of: getpid()).contains(busy.processIdentifier))
        #expect(LiveBrewActivityProbe.name(of: busy.processIdentifier) == "yes")

        let probe = LiveBrewActivityProbe(downloadsDirectory: try temporaryDirectory())
        await probe.start(at: .now)
        let first = await probe.sample()
        try await Task.sleep(for: .milliseconds(300))
        let second = await probe.sample()
        #expect(second.cpuTime > first.cpuTime)
    }

    @Test(
        "el nombre del proceso dice en qué está brew",
        arguments: [
            ("curl", BrewBusyWith.downloading),
            ("tar", .unpacking),
            ("clang", .compiling),
            ("cmake", .compiling),
            ("installer", .installing),
            ("ruby", nil),
            ("bash", nil),
        ] as [(String, BrewBusyWith?)]
    )
    func busyWithFromName(name: String, busy: BrewBusyWith?) {
        #expect(BrewBusyWith(processName: name) == busy)
    }
}
