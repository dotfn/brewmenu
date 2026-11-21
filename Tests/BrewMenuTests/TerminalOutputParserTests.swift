@testable import BrewMenu
import Foundation
import Testing

@Suite("TerminalOutputParser — la salida de brew en una pseudo-terminal")
struct TerminalOutputParserTests {
    /// `brew fetch --force --deps wget` recorded on a 120×40 pseudo-terminal with `TERM` set, the
    /// way the app runs brew: ten packages, twenty downloads, the block redrawn in place.
    private func recording() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/brew-fetch-deps-wget.pty")
        return try Data(contentsOf: url)
    }

    private func replay(_ data: Data, chunkSize: Int) -> [TerminalOutputParser.Event] {
        var parser = TerminalOutputParser()
        var events: [TerminalOutputParser.Event] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            events += parser.consume(data.subdata(in: offset ..< end))
            offset = end
        }
        return events
    }

    private func lines(_ events: [TerminalOutputParser.Event]) -> [String] {
        events.compactMap { if case let .line(text) = $0 { text } else { nil } }
    }

    private func progress(_ events: [TerminalOutputParser.Event]) -> [String] {
        events.compactMap { if case let .progress(text) = $0 { text } else { nil } }
    }

    @Test(
        "cada descarga llega al log una vez, al terminar, como por la tubería; nada de escapes",
        arguments: [1, 7, 4096]
    )
    func eachDownloadOnceInTheLog(chunkSize: Int) throws {
        let lines = lines(replay(try recording(), chunkSize: chunkSize))

        #expect(lines
            .first ==
            "Fetching: wget, libunistring, cmake, json-c, gettext, pkgconf, libidn2, libpsl, ca-certificates, openssl@4")
        let downloads = lines.dropFirst()
        #expect(downloads.count == 20, "lines: \(lines)")
        #expect(Set(downloads).count == downloads.count, "each one once")
        #expect(downloads.contains("✔︎ Bottle wget (1.25.0_2)"))
        #expect(downloads.contains("✔︎ Bottle openssl@4 (4.1.0)"))
        #expect(!lines.contains { $0.contains("\u{1B}") || $0.contains("\r") })
    }

    @Test("el progreso es el real de lo que se descarga ahora: sube mientras dura cada descarga y acaba en 100 %")
    func progressIsRealAndClimbs() throws {
        // Small reads, like each redraw arriving as its own write.
        let summaries = progress(replay(try recording(), chunkSize: 32))
        let percents = summaries.compactMap(CommandProgress.parsePercent(from:))
        #expect(percents.count == summaries.count, "every summary carries a percentage: \(summaries)")
        #expect(summaries.contains { $0.hasPrefix("Downloading ") })
        #expect(summaries.last?.hasPrefix("Downloaded ") == true)
        #expect(percents.last == 1)

        // While the same downloads run (same total), the percentage only goes up. The 11.5MB
        // openssl bottle, alone at the end of this recording, is the longest such stretch.
        let running = summaries.filter { $0.hasPrefix("Downloading ") }
        let byTotal = Dictionary(grouping: running) { $0.split(separator: "/").last?.split(separator: " ").first ?? "" }
        let openssl = try #require(byTotal["11.5MB"], "summaries: \(summaries)")
        let opensslPercents = openssl.compactMap(CommandProgress.parsePercent(from:))
        #expect(opensslPercents.count > 3, "summaries: \(openssl)")
        #expect(opensslPercents == opensslPercents.sorted(), "percentages: \(opensslPercents)")
    }

    @Test("las filas de una descarga se leen con su fase y sus bytes", arguments: [
        (
            "⠲ Bottle openssl@4 (4.1.0)                     ##   Downloading   5.3MB/ 11.5MB",
            DownloadRow(status: .active, label: "Bottle openssl@4 (4.1.0)", phase: "Downloading",
                        fetched: 5_300_000, total: 11_500_000)
        ),
        (
            "✔︎ Bottle Manifest pkgconf (3.0.11)                  Verified      3.6KB/  3.6KB",
            DownloadRow(status: .done, label: "Bottle Manifest pkgconf (3.0.11)", phase: "Verified",
                        fetched: 3600, total: 3600)
        ),
        (
            "⠋ Bottle ca-certificates (2026-11-05)",
            DownloadRow(status: .active, label: "Bottle ca-certificates (2026-11-05)", phase: nil,
                        fetched: nil, total: nil)
        ),
        (
            "✘ Bottle broken (1.0)                               Downloading 12.0KB/-------",
            DownloadRow(status: .failed, label: "Bottle broken (1.0)", phase: "Downloading",
                        fetched: 12000, total: nil)
        ),
    ])
    func row(text: String, expected: DownloadRow) {
        #expect(DownloadRow(text) == expected)
    }

    @Test("lo que no es una fila de descarga no se toma por una", arguments: [
        "==> Upgrading gh",
        "Fetching: wget, openssl@4",
        "🍺  /opt/homebrew/Cellar/gh/2.105.0: 213 files, 54.1MB",
        "###########                47.5%",
    ])
    func notARow(text: String) {
        #expect(DownloadRow(text) == nil)
    }

    @Test("los controles de terminal se quitan y queda el texto")
    func plainText() {
        #expect(TerminalText.plain("\u{1B}[?25l\u{1B}[?2026h⠋ Bottle x (1.0)\u{1B}[K\u{1B}[2F") == "⠋ Bottle x (1.0)")
        #expect(TerminalText.plain("\u{1B}]0;title\u{07}==> Pouring x   ") == "==> Pouring x")
    }
}
