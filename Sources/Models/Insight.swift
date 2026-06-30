import Foundation

struct Insight: Sendable, Identifiable, Equatable {
    enum Severity: Sendable, Equatable { case info, warning, critical }

    let id: String           // stable across re-runs for the same condition
    let severity: Severity
    let title: String
    let detail: String
}
