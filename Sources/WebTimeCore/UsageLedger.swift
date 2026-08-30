import Foundation

public struct UsageLedger: Sendable {
  public private(set) var usage: DailyUsage
  private let calendar: Calendar

  public init(usage: DailyUsage? = nil, now: Date = Date(), calendar: Calendar = .current) {
    self.calendar = calendar
    self.usage = usage ?? DailyUsage(day: Self.dayKey(for: now, calendar: calendar))
  }

  public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  public mutating func resetIfNeeded(at date: Date) {
    let key = Self.dayKey(for: date, calendar: calendar)
    guard usage.day != key else { return }
    usage = DailyUsage(day: key)
  }

  /// Records at most 30 seconds per tick so sleep/wake or a stalled app never consumes hours at once.
  @discardableResult
  public mutating func tick(
    at date: Date, activeSiteIDs: Set<String>, limits: [String: TimeInterval]
  ) -> [String: TimeInterval] {
    resetIfNeeded(at: date)
    defer { usage.lastSampleAt = date }
    guard !activeSiteIDs.isEmpty, let previous = usage.lastSampleAt else { return [:] }
    let delta = max(0, min(30, date.timeIntervalSince(previous)))
    var appliedBySite: [String: TimeInterval] = [:]
    for siteID in activeSiteIDs {
      guard let limit = limits[siteID] else { continue }
      let consumed = usage.consumedBySite[siteID, default: 0]
      let applied = min(delta, max(0, limit - consumed))
      usage.consumedBySite[siteID] = consumed + applied
      appliedBySite[siteID] = applied
    }
    return appliedBySite
  }

  public func consumed(siteID: String) -> TimeInterval {
    usage.consumedBySite[siteID, default: 0]
  }

  public func shouldBlock(siteID: String, limit: TimeInterval) -> Bool {
    consumed(siteID: siteID) >= limit
  }
}
