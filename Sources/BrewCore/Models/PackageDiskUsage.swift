import Foundation

/// How much disk space one installed package's Cellar/Caskroom directory actually
/// uses — computed on demand (not part of `InstalledPackage`, which comes from a
/// single fast `brew info --json` call; sizing every package means walking its
/// whole directory tree, too slow to do on every load).
public struct PackageDiskUsage: Identifiable, Hashable, Sendable {
    public let name: String
    public let isCask: Bool
    public let sizeBytes: Int64

    public var id: String {
        "\(name)-\(isCask)"
    }

    public init(
        name: String,
        isCask: Bool,
        sizeBytes: Int64
    ) {
        self.name = name
        self.isCask = isCask
        self.sizeBytes = sizeBytes
    }
}
