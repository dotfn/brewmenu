import Foundation

public struct Insight: Identifiable, Equatable, Sendable {
    public enum Severity: Equatable, Sendable { case info, warning, critical }

    public let id: String // stable across re-runs for the same condition
    public let severity: Severity
    public let title: String
    public let detail: String

    public init(id: String, severity: Severity, title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}
