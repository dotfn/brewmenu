public struct DoctorWarning: Codable, Identifiable, Equatable, Sendable {
    public enum Severity: String, Codable, Equatable, Sendable { case warning, error }
    public let severity: Severity
    public let message: String
    public var id: String {
        message
    }

    public init(
        severity: Severity,
        message: String
    ) {
        self.severity = severity
        self.message = message
    }
}
