import Foundation

/// A formula or cask matched by `brew search` — may or may not be installed.
public struct SearchResult: Identifiable, Equatable, Sendable {
    public let name: String
    public let isCask: Bool

    public var id: String {
        "\(name)-\(isCask)"
    }

    public init(
        name: String,
        isCask: Bool
    ) {
        self.name = name
        self.isCask = isCask
    }
}
