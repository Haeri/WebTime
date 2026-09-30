import Foundation
import SystemConfiguration
import WebTimeCore

protocol NetworkDNSProviding: Sendable {
  func setDomains(_ domains: [String]) -> Bool
  func snapshot() -> (identifier: Data, resolvers: [DNSResolver])
  func flushCaches()
}

/// The only configuration we publish is a session-owned supplemental resolver.
/// configd removes it if the daemon exits, including an unexpected crash.
final class NetworkDNS: NetworkDNSProviding, @unchecked Sendable {
  static let port = 5354
  private static let key = "State:/Network/Service/local.web-time/DNS"
  private let store: SCDynamicStore
  private let lock = NSLock()
  private var domains: [String] = []

  init() throws {
    guard let store = SCDynamicStoreCreateWithOptions(
      nil, "Web Time" as CFString,
      [kSCDynamicStoreUseSessionKeys: true] as CFDictionary, nil, nil)
    else { throw POSIXError(.EIO) }
    self.store = store
  }

  func setDomains(_ newDomains: [String]) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let normalized = SiteDomains.normalizedUnique(newDomains).sorted()
    if normalized.isEmpty {
      if SCDynamicStoreCopyValue(store, Self.key as CFString) != nil,
        !SCDynamicStoreRemoveValue(store, Self.key as CFString) { return false }
    } else {
      let settings: [String: Any] = [
        kSCPropNetDNSServerAddresses as String: ["127.0.0.1"],
        kSCPropNetDNSServerPort as String: Self.port,
        kSCPropNetDNSSupplementalMatchDomains as String: normalized,
        kSCPropNetDNSSupplementalMatchOrders as String: normalized.map { _ in 1 },
        "SupplementalMatchDomainsNoSearch": 1,
      ]
      // Re-publish if configd restarted and discarded the session's key.
      if normalized != domains || SCDynamicStoreCopyValue(store, Self.key as CFString) == nil {
        guard SCDynamicStoreSetValue(store, Self.key as CFString, settings as CFDictionary)
        else { return false }
      }
    }
    domains = normalized
    return true
  }

  /// Cached positive or negative answers would otherwise outlive a limit change.
  func flushCaches() {
    DispatchQueue.global(qos: .utility).async {
      for (path, arguments) in [
        ("/usr/bin/dscacheutil", ["-flushcache"]), ("/usr/bin/killall", ["-HUP", "mDNSResponder"]),
      ] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
      }
    }
  }

  func snapshot() -> (identifier: Data, resolvers: [DNSResolver]) {
    lock.lock()
    defer { lock.unlock() }
    // A single atomic snapshot avoids mixing DNS from one network with another's route.
    let patterns = ["State:/Network/Global/.*", "State:/Network/Service/.*/(DNS|IPv4|IPv6)"]
    let values = SCDynamicStoreCopyMultiple(store, nil, patterns as CFArray)
      as? [String: [String: Any]] ?? [:]
    return Self.configuration(from: values)
  }

  static func configuration(from snapshot: [String: [String: Any]]) -> (identifier: Data, resolvers: [DNSResolver]) {
    var values = snapshot
    values.removeValue(forKey: Self.key)
    let fingerprintKeys: Set<String> = [
      "ServerAddresses", "ServerPort", "SupplementalMatchDomains", "SupplementalMatchOrders",
      "SearchOrder", "PrimaryService", "PrimaryInterface", "InterfaceName", "Addresses", "Router",
    ]
    let fingerprint = values.mapValues { $0.filter { fingerprintKeys.contains($0.key) } }
    let identifier = (try? JSONSerialization.data(withJSONObject: fingerprint, options: .sortedKeys))
      ?? Data()
    var resolvers: [DNSResolver] = []
    if let global = values["State:/Network/Global/DNS"] {
      resolvers.append(DNSResolver(servers: global["ServerAddresses"] as? [String] ?? [],
          port: global["ServerPort"] as? Int ?? 53))
    }
    // Include current primary services if configd has not published Global/DNS yet.
    for family in ["IPv4", "IPv6"] {
      if let primary = values["State:/Network/Global/\(family)"]?["PrimaryService"] as? String,
        let dns = values["State:/Network/Service/\(primary)/DNS"],
        (dns["SupplementalMatchDomains"] as? [String] ?? []).isEmpty {
        resolvers.append(DNSResolver(servers: servers(dns, key: "State:/Network/Service/\(primary)/DNS", values: values), port: dns["ServerPort"] as? Int ?? 53))
      }
    }
    for key in values.keys.sorted() where key.hasSuffix("/DNS") {
      guard let dns = values[key], let domains = dns["SupplementalMatchDomains"] as? [String],
        !domains.isEmpty else { continue }
      let orders = dns["SupplementalMatchOrders"] as? [Int] ?? []
      for (index, domain) in domains.enumerated() {
        resolvers.append(DNSResolver(
          servers: servers(dns, key: key, values: values), domains: [domain],
          order: orders.indices.contains(index) ? orders[index] : (dns["SearchOrder"] as? Int ?? 200_000),
          port: dns["ServerPort"] as? Int ?? 53))
      }
    }
    return (identifier, resolvers)
  }

  private static func servers(_ dns: [String: Any], key: String, values: [String: [String: Any]]) -> [String] {
    let prefix = String(key.dropLast(3))
    let interface = dns["InterfaceName"] as? String
      ?? values[prefix + "IPv6"]?["InterfaceName"] as? String
      ?? values[prefix + "IPv4"]?["InterfaceName"] as? String
    return (dns["ServerAddresses"] as? [String] ?? []).map { address in
      if address.lowercased().hasPrefix("fe80:"), !address.contains("%"), let interface {
        return address + "%" + interface
      }
      return address
    }
  }
}
