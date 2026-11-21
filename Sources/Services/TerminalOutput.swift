import Foundation

/// Turns what brew writes to a sized pseudo-terminal into the app's two streams: finished lines for
/// the log, and in-place progress.
///
/// On a terminal, Homebrew draws its downloads as a block of rows it keeps redrawing
/// (`download_queue.rb`): each row `<status> <label> [bar] <Phase> <fetched>/<total>`, ended with
/// `ESC[K`, and the block rewound with `ESC[nF` / `ESC[0G` between redraws. Split on `\r`/`\n` the
/// way a pipe's output is, every redraw would land in the log; read this way, a download reaches
/// the log once, when it's done — as the pipe showed it — and the block in between becomes one
/// summary with a real percentage.
struct TerminalOutputParser {
    enum Event: Equatable {
        case line(String)
        case progress(String)
    }

    private var pending = Data()
    private var downloads = DownloadBlock()
    private var lastSummary: String?

    mutating func consume(_ data: Data) -> [Event] {
        pending.append(data)
        var events: [Event] = []
        var downloadsChanged = false
        var start = pending.startIndex
        var index = pending.startIndex
        while index < pending.endIndex {
            let byte = pending[index]
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                let raw = String(decoding: pending[start ..< index], as: UTF8.self)
                let text = TerminalText.plain(raw)
                if !text.isEmpty {
                    if let row = DownloadRow(text) {
                        downloadsChanged = true
                        if let finished = downloads.update(row) { events.append(.line(finished)) }
                    } else {
                        events.append(byte == UInt8(ascii: "\n") ? .line(text) : .progress(text))
                    }
                }
                start = pending.index(after: index)
            }
            index = pending.index(after: index)
        }
        pending = Data(pending[start...])
        if downloadsChanged, let summary = downloads.summary, summary != lastSummary {
            lastSummary = summary
            events.append(.progress(summary))
        }
        return events
    }
}

/// Text with terminal control removed.
enum TerminalText {
    /// Drops ECMA-48 control sequences (`ESC[…` with its final byte, `ESC]…` up to BEL or `ESC\`,
    /// and two-byte `ESC x`), other C0 controls but tab, and trailing spaces — rows are padded to
    /// the terminal's width.
    static func plain(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            switch scalar.value {
            case 0x1B:
                skipEscape(&scalars)
            case 0x09, 0x20...:
                output.append(scalar)
            default:
                continue
            }
        }
        var plain = String(output)
        while plain.last == " " {
            plain.removeLast()
        }
        return plain
    }

    private static func skipEscape(_ scalars: inout String.UnicodeScalarView.Iterator) {
        guard let introducer = scalars.next() else { return }
        switch introducer {
        case "[":
            // Parameters and intermediates, then one final byte in 0x40...0x7E.
            while let scalar = scalars.next(), !(0x40 ... 0x7E).contains(scalar.value) {}
        case "]":
            // Operating system command: ends at BEL or `ESC \`.
            while let scalar = scalars.next() {
                if scalar.value == 0x07 { return }
                if scalar.value == 0x1B { _ = scalars.next(); return }
            }
        default:
            return
        }
    }
}

/// One row of Homebrew's download block, as plain text.
struct DownloadRow: Equatable {
    enum Status: Equatable {
        case active, done, failed
    }

    let status: Status
    let label: String
    let phase: String?
    let fetched: Int64?
    let total: Int64?

    /// `✔︎` done, `✘` failed, a braille spinner frame while it runs; then the label, and — once
    /// there's a size — an optional `#` bar, the phase, and `fetched/total` (`-------` while the total
    /// is unknown).
    init?(_ text: String) {
        guard let first = text.unicodeScalars.first else { return nil }
        let status: Status
        switch first.value {
        case 0x2714: status = .done
        case 0x2718: status = .failed
        case 0x2800 ... 0x28FF: status = .active
        default: return nil
        }
        // The status, its optional text-style selector, then one space.
        var rest = Substring(text).unicodeScalars.dropFirst()
        if rest.first?.value == 0xFE0E { rest = rest.dropFirst() }
        guard rest.first == " " else { return nil }
        let body = String(String.UnicodeScalarView(rest.dropFirst()))

        if let match = body.firstMatch(of: Self.sizes) {
            label = String(body[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            phase = String(match.output.phase)
            fetched = Self.bytes(match.output.fetched)
            total = Self.bytes(match.output.total)
        } else {
            label = body.trimmingCharacters(in: .whitespaces)
            phase = nil
            fetched = nil
            total = nil
        }
        guard !label.isEmpty else { return nil }
        self.status = status
    }

    /// `  ###   Downloading   5.3MB/ 11.5MB` at the end of a row.
    private nonisolated(unsafe) static let sizes =
        /\s+#*\s*(?<phase>[A-Z][a-z]+)\s+(?<fetched>[0-9.]+[KMGT]?B)\/\s*(?<total>[0-9.]+[KMGT]?B|-+)$/

    /// Homebrew's sizes are decimal (`Formatter.disk_usage_readable_size_unit` divides by 1000).
    static func bytes(_ text: Substring) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (unit, factor) in units where text.hasSuffix(unit) {
            guard let value = Double(text.dropLast(unit.count)) else { return nil }
            return Int64(value * factor)
        }
        return nil
    }
}

/// Every download of the run, by label, and their sum.
struct DownloadBlock {
    private var rows: [DownloadRow] = []
    private var announced: Set<String> = []

    /// Records `row`, and returns the log line for a download that just finished — once, in the
    /// pipe's own words (`✔︎ Bottle wget (1.25.0_2)`).
    mutating func update(_ row: DownloadRow) -> String? {
        // A label can come cut short on a narrow row; it's the same download as the longer one.
        if let index = rows.firstIndex(where: { $0.label.hasPrefix(row.label) || row.label.hasPrefix($0.label) }) {
            let previous = rows[index]
            rows[index] = DownloadRow(
                status: row.status,
                label: previous.label.count >= row.label.count ? previous.label : row.label,
                phase: row.phase ?? previous.phase,
                fetched: row.fetched ?? previous.fetched,
                total: row.total ?? previous.total
            )
        } else {
            rows.append(row)
        }
        guard row.status != .active else { return nil }
        let label = rows.first { $0.label.hasPrefix(row.label) || row.label.hasPrefix($0.label) }?.label ?? row.label
        guard announced.insert(label).inserted else { return nil }
        return "\(row.status == .done ? "✔︎" : "✘") \(label)"
    }

    /// "Downloading 5.3MB/11.5MB (46%)" over the downloads in progress, once one has a size;
    /// "Downloaded 37.6MB/37.6MB (100%)" over all of them when none is left running.
    ///
    /// Not one figure for the whole run: Homebrew doesn't say up front how many downloads there will
    /// be or how big, so a run-wide percentage went back down — from 100% to 77% on a real run —
    /// every time a new one appeared. Over what's downloading now it only starts again when another
    /// download does, which is what's happening.
    var summary: String? {
        let active = rows.filter { $0.status == .active && $0.total != nil }
        let counted = active.isEmpty ? rows.filter { $0.total != nil } : active
        let fetched = counted.reduce(Int64(0)) { $0 + min($1.fetched ?? 0, $1.total ?? 0) }
        let total = counted.reduce(Int64(0)) { $0 + ($1.total ?? 0) }
        guard total > 0 else { return nil }
        let percent = Int((Double(fetched) / Double(total) * 100).rounded(.down))
        let phase = active.isEmpty ? "Downloaded" : "Downloading"
        return "\(phase) \(Self.size(fetched))/\(Self.size(total)) (\(percent)%)"
    }

    /// Homebrew's own style: decimal, one decimal place.
    static func size(_ bytes: Int64) -> String {
        var value = Double(bytes)
        var unit = "B"
        for next in ["KB", "MB", "GB"] where value >= 1000 {
            value /= 1000
            unit = next
        }
        return unit == "B" ? "\(bytes)B" : String(format: "%.1f%@", value, unit)
    }
}

extension DownloadRow {
    init(status: Status, label: String, phase: String?, fetched: Int64?, total: Int64?) {
        self.status = status
        self.label = label
        self.phase = phase
        self.fetched = fetched
        self.total = total
    }
}
