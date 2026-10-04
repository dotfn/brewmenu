struct DoctorWarning: Codable, Identifiable, Equatable {
    enum Severity: String, Codable, Equatable { case warning, error }
    let severity: Severity
    let message: String
    var id: String {
        message
    }
}
