import Foundation

/// One file in Homebrew's download cache (`brew --cache`) — a downloaded bottle or
/// cask installer, kept around so a future install/upgrade doesn't re-download it.
struct CacheEntry: Identifiable, Hashable {
    let path: URL
    let sizeBytes: Int64
    let modifiedDate: Date

    var id: String {
        path.path
    }

    var name: String {
        path.lastPathComponent
    }
}
