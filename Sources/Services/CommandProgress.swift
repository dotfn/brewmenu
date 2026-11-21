import Foundation

/// One event from a running `brew` subprocess, in the order it was produced — a
/// completed line, or an in-place progress update (curl's own `\r`-terminated
/// download meter). Shared by every flow that shows a determinate progress bar:
/// `DashboardViewModel`'s installs and `MenuBarViewModel`'s upgrades.
enum CommandOutputEvent {
    case line(String)
    case progress(String)
}

/// Turns a `brew` subprocess's progress text into a 0...1 fraction — the same whether the
/// command is an install or an upgrade, so it lives here once.
enum CommandProgress {
    /// Pulls a trailing "NN.N%" (curl's own progress-meter format) out of a raw
    /// progress-update string and returns it as a 0...1 fraction, or `nil` if the
    /// text isn't a percentage (a connection-phase message, say).
    static func parsePercent(from text: String) -> Double? {
        guard let percentRange = text.range(of: "%", options: .backwards) else { return nil }
        var start = percentRange.lowerBound
        while start > text.startIndex {
            let prev = text.index(before: start)
            let c = text[prev]
            guard c.isNumber || c == "." else { break }
            start = prev
        }
        guard start < percentRange.lowerBound, let value = Double(text[start ..< percentRange.lowerBound]) else {
            return nil
        }
        return min(max(value / 100, 0), 1)
    }
}
