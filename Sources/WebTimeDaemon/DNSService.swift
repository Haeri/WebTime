import Darwin
import Foundation
import WebTimeCore

final class DaemonState: @unchecked Sendable {
  let instanceID = UUID().uuidString
  let network: any NetworkDNSProviding
  private let lock = NSLock()
  private var policies: [DaemonSitePolicy] = []
  private var observations = DNSObservations()

  init(network: any NetworkDNSProviding) { self.network = network }

  func snapshot() -> [String: [String]] {
    lock.lock()
    defer { lock.unlock() }
    observations.useNetwork(network.snapshot().identifier)
    return observations.snapshot()
  }

  func status() -> DaemonStatus {
    lock.lock()
    defer { lock.unlock() }
    observations.useNetwork(network.snapshot().identifier)
    let ok = network.setDomains(policies.flatMap(\.domains))
    return DaemonStatus(ok: ok, learnedAddressesBySite: observations.snapshot(), instanceID: instanceID)
  }

  private func matching(_ host: String) -> DaemonSitePolicy? {
    policies.compactMap { policy -> (DaemonSitePolicy, Int)? in
      guard let length = policy.domains.filter({ SiteDomains.host(host, matchesAny: [$0]) })
        .map({ SiteDomains.normalize($0).count }).max() else { return nil }
      return (policy, length)
    }.sorted {
      if $0.1 != $1.1 { return $0.1 > $1.1 }
      if $0.0.blocked != $1.0.blocked { return $0.0.blocked }
      return $0.0.id < $1.0.id
    }.first?.0
  }

  func isBlocked(_ host: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return matching(host)?.blocked == true
  }

  func updatePolicies(_ newPolicies: [DaemonSitePolicy]) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard network.setDomains(newPolicies.flatMap(\.domains)) else { return false }
    let unchangedDomains = Set(newPolicies.filter { new in
      policies.contains { $0.id == new.id && $0.domains == new.domains }
    }.map(\.id))
    observations.removeSites(except: unchangedDomains)
    let blockedBefore = Set(policies.filter(\.blocked).flatMap(\.domains))
    policies = newPolicies
    if Set(policies.filter(\.blocked).flatMap(\.domains)) != blockedBefore { network.flushCaches() }
    return true
  }

  func finish(_ response: Data, query: Data, host: String, networkID: Data) -> Data {
    lock.lock()
    defer { lock.unlock() }
    // Recheck after I/O: a limit can expire while an upstream query is in flight.
    if matching(host)?.blocked == true { return DNSMessage.nxdomainResponse(for: query)! }
    let currentNetwork = network.snapshot().identifier
    observations.useNetwork(currentNetwork)
    guard currentNetwork == networkID else { return DNSMessage.serverFailureResponse(for: query)! }
    if let policy = matching(host) {
      observations.learn(DNSMessage.addresses(in: response), siteID: policy.id)
      return DNSMessage.limitingAnswerTTL(response, to: 30)
    }
    return response
  }
}

final class DNSProxy: @unchecked Sendable {
  private let state: DaemonState
  private let udp: Int32
  private let tcp: Int32
  private let queue = DispatchQueue(label: "local.web-time.dns", qos: .userInitiated, attributes: .concurrent)
  private let capacity = DispatchSemaphore(value: 32)

  init(state: DaemonState, port: Int = NetworkDNS.port) throws {
    self.state = state
    udp = try DNSTransport.listener(type: SOCK_DGRAM, port: port)
    do { tcp = try DNSTransport.listener(type: SOCK_STREAM, port: port) }
    catch { close(udp); throw error }
  }

  deinit { close(udp); close(tcp) }

  func run() -> Never {
    DispatchQueue(label: "local.web-time.dns.tcp").async { [self] in
      while true {
        let client = accept(tcp, nil, nil)
        guard client >= 0 else { continue }
        guard capacity.wait(timeout: .now()) == .success else { close(client); continue }
        queue.async { [self] in
          defer { close(client); capacity.signal() }
          DNSTransport.configure(client)
          for _ in 0..<16 {
            guard let query = DNSTransport.readFrame(from: client, until: Date().addingTimeInterval(3)),
              DNSMessage.isStandardQuery(query) else { return }
            let response = resolve(query, tcp: true)
            guard DNSTransport.writeFrame(response, to: client, until: Date().addingTimeInterval(1)) else { return }
          }
        }
      }
    }
    while true {
      var buffer = [UInt8](repeating: 0, count: 65_535)
      var client = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let count = withUnsafeMutablePointer(to: &client) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          recvfrom(udp, &buffer, buffer.count, 0, $0, &length)
        }
      }
      guard count > 0 else { continue }
      let query = Data(buffer.prefix(Int(count)))
      guard DNSMessage.isStandardQuery(query) else { continue }
      guard capacity.wait(timeout: .now()) == .success else {
        sendUDP(DNSMessage.serverFailureResponse(for: query)!, to: client, length: length)
        continue
      }
      let destination = client
      let destinationLength = length
      queue.async { [self] in
        defer { capacity.signal() }
        sendUDP(resolve(query, tcp: false), to: destination, length: destinationLength)
      }
    }
  }

  private func sendUDP(_ response: Data, to destination: sockaddr_storage, length: socklen_t) {
    var destination = destination
    response.withUnsafeBytes { bytes in
      withUnsafePointer(to: &destination) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          _ = sendto(udp, bytes.baseAddress, bytes.count, 0, $0, length)
        }
      }
    }
  }

  func resolve(_ query: Data, tcp: Bool) -> Data {
    let host = DNSMessage.questionName(in: query)!
    if state.isBlocked(host) { return DNSMessage.nxdomainResponse(for: query)! }
    // Retry with a fresh snapshot once if the network changes during resolution.
    for _ in 0..<2 {
      let snapshot = state.network.snapshot()
      for server in DNSRouting.upstreams(for: host, resolvers: snapshot.resolvers).prefix(3) {
        guard var response = DNSTransport.exchange(query, server: server, tcp: tcp) else { continue }
        if response[3] & 0x0f == 2 || response[3] & 0x0f == 5 { continue }
        if !tcp && response[2] & 0x02 != 0 {
          // Return truncation to the client if upstream TCP fails; it may retry over TCP.
          response = DNSTransport.exchange(query, server: server, tcp: true) ?? response
        }
        if state.network.snapshot().identifier != snapshot.identifier { break }
        // Respect the client's UDP payload size even after an upstream TCP retry.
        if !tcp && response.count > DNSMessage.udpPayloadSize(query) {
          response = DNSMessage.truncatedResponse(for: query)!
        }
        return state.finish(response, query: query, host: host, networkID: snapshot.identifier)
      }
      if state.network.snapshot().identifier == snapshot.identifier { break }
    }
    return state.isBlocked(host)
      ? DNSMessage.nxdomainResponse(for: query)!
      : DNSMessage.serverFailureResponse(for: query)!
  }
}

