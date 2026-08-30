import Foundation

public struct ControlsSession: Equatable, Sendable {
  public private(set) var unlockedUntil: Date?

  public init() {}

  public func isUnlocked(at date: Date) -> Bool {
    guard let unlockedUntil else { return false }
    return date < unlockedUntil
  }

  public mutating func unlock(at date: Date, inactivityTimeout: TimeInterval) {
    unlockedUntil = date.addingTimeInterval(inactivityTimeout)
  }

  public mutating func recordInteraction(at date: Date, inactivityTimeout: TimeInterval) {
    guard isUnlocked(at: date) else { return }
    unlockedUntil = date.addingTimeInterval(inactivityTimeout)
  }

  public mutating func lock() { unlockedUntil = nil }
}
