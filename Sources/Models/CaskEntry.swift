import Foundation

struct CaskEntry: Codable, Identifiable, Equatable {
    let name: String
    let version: String
    var id: String {
        name
    }
}
