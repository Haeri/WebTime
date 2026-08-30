import Foundation

public struct SiteConfiguration: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var domains: [String]
  public var dailyLimitSeconds: TimeInterval

  public init(
    id: String = UUID().uuidString, name: String, domains: [String], dailyLimitSeconds: TimeInterval
  ) {
    self.id = id
    self.name = name
    self.domains = domains
    self.dailyLimitSeconds = dailyLimitSeconds
  }

  public var primaryDomain: String { domains.first ?? "" }
}

public struct LimiterConfiguration: Codable, Equatable, Sendable {
  public var sites: [SiteConfiguration]
  public var idleGraceSeconds: TimeInterval
  public var controlsInactivitySeconds: TimeInterval

  public init(
    sites: [SiteConfiguration] = [],
    idleGraceSeconds: TimeInterval = 30,
    controlsInactivitySeconds: TimeInterval = 5 * 60
  ) {
    self.sites = sites
    self.idleGraceSeconds = idleGraceSeconds
    self.controlsInactivitySeconds = controlsInactivitySeconds
  }
}

public struct DailyUsage: Codable, Equatable, Sendable {
  public var day: String
  public var consumedBySite: [String: TimeInterval]
  public var lastSampleAt: Date?

  public init(
    day: String, consumedBySite: [String: TimeInterval] = [:], lastSampleAt: Date? = nil
  ) {
    self.day = day
    self.consumedBySite = consumedBySite
    self.lastSampleAt = lastSampleAt
  }
}

public struct UsageHistory: Codable, Equatable, Sendable {
  public var days: [String: [String: TimeInterval]]
  public var hourly: [String: [String: [String: TimeInterval]]]
  public var limitHitHourBySite: [String: [String: Int]]

  public init(
    days: [String: [String: TimeInterval]] = [:],
    hourly: [String: [String: [String: TimeInterval]]] = [:],
    limitHitHourBySite: [String: [String: Int]] = [:]
  ) {
    self.days = days
    self.hourly = hourly
    self.limitHitHourBySite = limitHitHourBySite
  }

  public mutating func record(
    totals: [String: TimeInterval], increments: [String: TimeInterval], at date: Date,
    limits: [String: TimeInterval], calendar: Calendar = .current
  ) {
    let day = UsageLedger.dayKey(for: date, calendar: calendar)
    days[day] = totals
    let hourValue = calendar.component(.hour, from: date)
    let hour = String(format: "%02d", hourValue)
    for (siteID, seconds) in increments where seconds > 0 {
      hourly[day, default: [:]][hour, default: [:]][siteID, default: 0] += seconds
    }
    for (siteID, limit) in limits where limit > 0 && totals[siteID, default: 0] >= limit {
      if limitHitHourBySite[day, default: [:]][siteID] == nil {
        limitHitHourBySite[day, default: [:]][siteID] = hourValue
      }
    }
  }

  public mutating func trim(keepingRecentDays maximumDays: Int) {
    let keysToRemove = days.keys.sorted().dropLast(max(0, maximumDays))
    for key in keysToRemove {
      days.removeValue(forKey: key)
      hourly.removeValue(forKey: key)
      limitHitHourBySite.removeValue(forKey: key)
    }
  }
}

public enum DaemonCommand: Codable, Sendable {
  case updatePolicies([DaemonSitePolicy])
  case status

  private enum CodingKeys: String, CodingKey { case action, policies }
  private enum Action: String, Codable { case updatePolicies, status }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Action.self, forKey: .action) {
    case .updatePolicies:
      self = .updatePolicies(try c.decode([DaemonSitePolicy].self, forKey: .policies))
    case .status: self = .status
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .updatePolicies(let policies):
      try c.encode(Action.updatePolicies, forKey: .action)
      try c.encode(policies, forKey: .policies)
    case .status:
      try c.encode(Action.status, forKey: .action)
    }
  }
}

public struct DaemonSitePolicy: Codable, Equatable, Sendable {
  public var id: String
  public var domains: [String]
  public var blocked: Bool

  public init(id: String, domains: [String], blocked: Bool) {
    self.id = id
    self.domains = domains
    self.blocked = blocked
  }
}

public enum DaemonPolicyValidator {
  public static let maximumSites = 128
  public static let maximumDomainsPerSite = 128

  public static func errorMessage(for policies: [DaemonSitePolicy]) -> String? {
    guard policies.count <= maximumSites else {
      return "Too many website policies."
    }
    var identifiers = Set<String>()
    for policy in policies {
      guard !policy.id.isEmpty, policy.id.utf8.count <= 128 else {
        return "A website policy has an invalid identifier."
      }
      guard identifiers.insert(policy.id).inserted else {
        return "Website policy identifiers must be unique."
      }
      guard !policy.domains.isEmpty, policy.domains.count <= maximumDomainsPerSite,
        policy.domains.allSatisfy(SiteDomains.isValid)
      else {
        return "A website policy contains invalid domains."
      }
    }
    return nil
  }
}

public struct DaemonStatus: Codable, Equatable, Sendable {
  public var ok: Bool
  public var learnedAddressesBySite: [String: [String]]
  public var message: String?

  public init(
    ok: Bool, learnedAddressesBySite: [String: [String]] = [:], message: String? = nil
  ) {
    self.ok = ok
    self.learnedAddressesBySite = learnedAddressesBySite
    self.message = message
  }
}

public enum AppPaths {
  public static let daemonSocket = "/var/run/web-time.sock"
  public static let supportDirectoryName = "Web Time"

  public static func supportDirectory(fileManager: FileManager = .default) throws -> URL {
    let base = try fileManager.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let url = base.appendingPathComponent(supportDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }
}
