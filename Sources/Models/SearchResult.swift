import Foundation

/// A formula or cask matched by `brew search` — may or may not be installed.
struct SearchResult: Sendable, Identifiable, Equatable {
    let name: String
    let isCask: Bool

    var id: String { "\(name)-\(isCask)" }
}
