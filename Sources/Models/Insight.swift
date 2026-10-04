import Foundation

struct Insight: Identifiable, Equatable {
    enum Severity: Equatable { case info, warning, critical }

    let id: String // stable across re-runs for the same condition
    let severity: Severity
    let title: String
    let detail: String
}
