import Foundation

struct ServiceEntry: Codable, Sendable, Identifiable, Equatable {
    enum Status: String, Codable, Sendable, Equatable {
        case started, stopped, error
        case inactive = "none"  // brew reports "none" for services that exist but aren't registered
        case unknown
    }

    let name: String
    let status: Status
    let user: String?
    let exitCode: Int?

    var id: String { name }
}
