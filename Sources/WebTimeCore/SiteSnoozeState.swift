import Foundation

public struct SiteSnoozeState: Sendable {
  public private(set) var endsBySite: [String: Date] = [:]

  public init() {}

  public mutating func snooze(
    siteID: String, at date: Date, duration: TimeInterval = 15 * 60
  ) {
    guard !siteID.isEmpty, duration > 0 else { return }
    endsBySite[siteID] = date.addingTimeInterval(duration)
  }

  public func isActive(siteID: String, at date: Date) -> Bool {
    guard let end = endsBySite[siteID] else { return false }
    return end > date
  }

  public func remaining(siteID: String, at date: Date) -> TimeInterval {
    max(0, endsBySite[siteID]?.timeIntervalSince(date) ?? 0)
  }

  @discardableResult
  public mutating func removeExpired(at date: Date) -> Bool {
    let previousCount = endsBySite.count
    endsBySite = endsBySite.filter { $0.value > date }
    return endsBySite.count != previousCount
  }

  public mutating func removeAll() {
    endsBySite.removeAll()
  }
}
