import Foundation

public enum SiteRanking {
  public static func mostUsed(
    _ sites: [SiteConfiguration],
    consumedBySite: [String: TimeInterval],
    limit: Int
  ) -> [SiteConfiguration] {
    guard limit > 0 else { return [] }

    return sites.enumerated()
      .sorted { left, right in
        let leftUsage = consumedBySite[left.element.id, default: 0]
        let rightUsage = consumedBySite[right.element.id, default: 0]
        if leftUsage != rightUsage { return leftUsage > rightUsage }
        return left.offset < right.offset
      }
      .prefix(limit)
      .map(\.element)
  }
}
