import Foundation

/// A formula or cask ranked by install popularity, from formulae.brew.sh's analytics API.
public struct TrendingPackage: Codable, Identifiable, Equatable, Sendable {
    public let name: String
    public let installCount: Int
    public let isCask: Bool

    public var id: String {
        name
    }

    public init(
        name: String,
        installCount: Int,
        isCask: Bool
    ) {
        self.name = name
        self.installCount = installCount
        self.isCask = isCask
    }
}

// MARK: - formulae.brew.sh analytics decoding

/// Wrapper for `/api/analytics/install/30d.json` and `/api/analytics/cask-install/30d.json`.
/// Both share the same shape; the item's key is "formula" or "cask" depending on endpoint.
public struct AnalyticsOutput: Decodable, Sendable {
    public struct Item: Decodable, Sendable {
        public let formula: String?
        public let cask: String?
        public let count: String
    }

    public let items: [Item]

    public func trendingPackages(isCask: Bool) -> [TrendingPackage] {
        items.compactMap { item -> TrendingPackage? in
            guard let name = isCask ? item.cask : item.formula else { return nil }
            let digits = item.count.filter(\.isNumber)
            guard let installCount = Int(digits) else { return nil }
            return TrendingPackage(name: name, installCount: installCount, isCask: isCask)
        }
    }

    public init(
        items: [Item]
    ) {
        self.items = items
    }
}
