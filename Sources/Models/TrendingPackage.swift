import Foundation

/// A formula or cask ranked by install popularity, from formulae.brew.sh's analytics API.
struct TrendingPackage: Codable, Sendable, Identifiable, Equatable {
    let name: String
    let installCount: Int
    let isCask: Bool

    var id: String { name }
}

// MARK: - formulae.brew.sh analytics decoding

/// Wrapper for `/api/analytics/install/30d.json` and `/api/analytics/cask-install/30d.json`.
/// Both share the same shape; the item's key is "formula" or "cask" depending on endpoint.
struct AnalyticsOutput: Decodable {
    struct Item: Decodable {
        let formula: String?
        let cask: String?
        let count: String
    }
    let items: [Item]

    func trendingPackages(isCask: Bool) -> [TrendingPackage] {
        items.compactMap { item -> TrendingPackage? in
            guard let name = isCask ? item.cask : item.formula else { return nil }
            let digits = item.count.filter(\.isNumber)
            guard let installCount = Int(digits) else { return nil }
            return TrendingPackage(name: name, installCount: installCount, isCask: isCask)
        }
    }
}
