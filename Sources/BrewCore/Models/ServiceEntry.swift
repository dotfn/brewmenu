import Foundation

public struct ServiceEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case started, stopped, error
        case inactive = "none" // brew reports "none" for services that exist but aren't registered
        case unknown
    }

    public let name: String
    public let status: Status
    public let user: String?
    public let exitCode: Int?

    public var id: String {
        name
    }

    public init(
        name: String,
        status: Status,
        user: String?,
        exitCode: Int?
    ) {
        self.name = name
        self.status = status
        self.user = user
        self.exitCode = exitCode
    }
}
