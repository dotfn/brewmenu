import Foundation

struct CaskEntry: Codable, Sendable, Identifiable, Equatable {
    let name: String
    let version: String
    var id: String { name }
}
