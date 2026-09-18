import Foundation

/// How much disk space one installed package's Cellar/Caskroom directory actually
/// uses — computed on demand (not part of `InstalledPackage`, which comes from a
/// single fast `brew info --json` call; sizing every package means walking its
/// whole directory tree, too slow to do on every load).
struct PackageDiskUsage: Identifiable, Hashable, Sendable {
    let name: String
    let isCask: Bool
    let sizeBytes: Int64

    var id: String { "\(name)-\(isCask)" }
}
