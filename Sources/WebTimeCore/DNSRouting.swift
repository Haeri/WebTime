import Foundation

/// Upstreams belong to the current network snapshot, never to an installation.
public struct DNSUpstream: Hashable, Sendable {
  public var address: String
  public var port: Int
  public init(address: String, port: Int = 53) { self.address = address; self.port = port }
}

public struct DNSResolver: Equatable, Sendable {
  public var servers: [String]
  public var domains: [String]
  public var order: Int
  public var port: Int

  public init(servers: [String], domains: [String] = [], order: Int = 200_000, port: Int = 53) {
    self.servers = servers
    self.domains = domains
    self.order = order
    self.port = port
  }
}

public enum DNSRouting {
  public static func upstreams(for host: String, resolvers: [DNSResolver]) -> [DNSUpstream] {
    let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let matches = resolvers.compactMap { resolver -> (DNSResolver, Int)? in
      let specificity = resolver.domains.isEmpty ? 0 : resolver.domains.compactMap { domain in
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain.isEmpty || host == domain || host.hasSuffix("." + domain)
          ? domain.count : nil
      }.max()
      guard let specificity else { return nil }
      return (resolver, specificity)
    }
    guard let longest = matches.map({ $0.1 }).max() else { return [] }
    // Never send a private split-DNS name to the default resolver when its resolver fails.
    var seen = Set<DNSUpstream>()
    return matches.filter { $0.1 == longest }.sorted { $0.0.order < $1.0.order }
      .flatMap { match in match.0.servers.map { DNSUpstream(address: $0, port: match.0.port) } }
      .filter { (1...65_535).contains($0.port) && seen.insert($0).inserted }
  }
}

/// Address observations are for usage attribution only, not firewall enforcement.
public struct DNSObservations: Sendable {
  private var networkID: Data?
  private var entries: [String: Set<String>] = [:]

  public init() {}

  public mutating func useNetwork(_ identifier: Data) {
    if networkID != identifier {
      entries.removeAll()
      networkID = identifier
    }
  }

  public mutating func removeSites(except siteIDs: Set<String>) {
    entries = entries.filter { siteIDs.contains($0.key) }
  }

  public mutating func learn(_ addresses: [String], siteID: String) {
    // Keep observations for existing long-lived connections even after DNS TTL expires.
    // They are bounded and discarded when the network or a site's domains change.
    let count = entries[siteID, default: []].count
    let total = entries.values.reduce(0) { $0 + $1.count }
    let remaining = max(0, min(512 - count, 4_096 - total))
    let newAddresses = Set(addresses).subtracting(entries[siteID, default: []]).sorted()
    entries[siteID, default: []].formUnion(newAddresses.prefix(remaining))
  }

  public func snapshot() -> [String: [String]] {
    entries.mapValues { $0.sorted() }
  }
}
