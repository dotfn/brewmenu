import Foundation

public struct CaskEntry: Codable, Identifiable, Equatable, Sendable {
    public let name: String
    public let version: String
    public var id: String {
        name
    }

    public init(
        name: String,
        version: String
    ) {
        self.name = name
        self.version = version
    }
}
