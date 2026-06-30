struct DoctorWarning: Codable, Sendable, Identifiable, Equatable {
    enum Severity: String, Codable, Sendable, Equatable { case warning, error }
    let severity: Severity
    let message: String
    var id: String { message }
}
