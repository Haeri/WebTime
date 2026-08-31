import Foundation

public struct AllowanceExtensionState: Sendable {
  public static let defaultDuration: TimeInterval = 15 * 60

  private var additionalSecondsBySite: [String: TimeInterval] = [:]

  public init() {}

  public mutating func grant(
    siteID: String, duration: TimeInterval = Self.defaultDuration
  ) {
    guard !siteID.isEmpty, duration > 0 else { return }
    additionalSecondsBySite[siteID, default: 0] += duration
  }

  public func additionalAllowance(siteID: String) -> TimeInterval {
    additionalSecondsBySite[siteID, default: 0]
  }

  public func effectiveLimit(siteID: String, baseLimit: TimeInterval) -> TimeInterval {
    baseLimit + additionalAllowance(siteID: siteID)
  }

  public mutating func removeAll() {
    additionalSecondsBySite.removeAll()
  }
}
