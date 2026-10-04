import Foundation

/// One file in Homebrew's download cache (`brew --cache`) — a downloaded bottle or
/// cask installer, kept around so a future install/upgrade doesn't re-download it.
public struct CacheEntry: Identifiable, Hashable, Sendable {
    public let path: URL
    public let sizeBytes: Int64
    public let modifiedDate: Date

    public var id: String {
        path.path
    }

    public var name: String {
        path.lastPathComponent
    }

    public init(
        path: URL,
        sizeBytes: Int64,
        modifiedDate: Date
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.modifiedDate = modifiedDate
    }
}
