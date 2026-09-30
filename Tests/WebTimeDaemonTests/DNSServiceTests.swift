import Darwin
import Foundation
import WebTimeCore

private final class FakeNetwork: NetworkDNSProviding, @unchecked Sendable {
  var identifier = Data("wifi".utf8)
  var resolvers: [DNSResolver] = []
  var domains: [String] = []
  var acceptsChanges = true
  var flushes = 0
  func setDomains(_ domains: [String]) -> Bool {
    guard acceptsChanges else { return false }
    self.domains = domains
    return true
  }
  func snapshot() -> (identifier: Data, resolvers: [DNSResolver]) { (identifier, resolvers) }
  func flushCaches() { flushes += 1 }
}

final class DNSServiceTests {
  private func query(_ name: String) -> Data {
    var data = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
    for label in name.split(separator: ".") {
      data.append(UInt8(label.utf8.count))
      data.append(contentsOf: label.utf8)
    }
    data.append(contentsOf: [0, 0, 1, 0, 1])
    return data
  }

  private func answer(_ query: Data) -> Data {
    var data = query
    data[2] = 0x81
    data[3] = 0x80
    data[7] = 1
    data.append(contentsOf: [0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34])
    return data
  }

  func testSystemConfigurationSnapshotFollowsPrimaryServiceAndExcludesOurRoute() {
    let old: [String: [String: Any]] = [
      "State:/Network/Global/IPv4": ["PrimaryService": "wifi"],
      "State:/Network/Service/wifi/DNS": ["ServerAddresses": ["192.168.1.1"]],
      "State:/Network/Service/local.web-time/DNS": [
        "ServerAddresses": ["127.0.0.1"], "ServerPort": 5354,
        "SupplementalMatchDomains": ["example.com"],
      ],
    ]
    let wifi = NetworkDNS.configuration(from: old)
    requireEqual(DNSRouting.upstreams(for: "example.com", resolvers: wifi.resolvers).map(\.address), ["192.168.1.1"])
    var current = old
    current["State:/Network/Global/IPv4"] = ["PrimaryService": "hotspot"]
    current["State:/Network/Service/hotspot/DNS"] = ["ServerAddresses": ["172.20.10.1"]]
    let hotspot = NetworkDNS.configuration(from: current)
    requireNotEqual(wifi.identifier, hotspot.identifier)
    requireEqual(DNSRouting.upstreams(for: "example.com", resolvers: hotspot.resolvers).map(\.address), ["172.20.10.1"])
    current.removeValue(forKey: "State:/Network/Service/local.web-time/DNS")
    requireEqual(hotspot.identifier, NetworkDNS.configuration(from: current).identifier)
    current["State:/Network/Service/vpn/DNS"] = [
      "ServerAddresses": ["fe80::53"], "SupplementalMatchDomains": ["corp.example"],
    ]
    current["State:/Network/Service/vpn/IPv6"] = ["InterfaceName": "utun5"]
    requireEqual(DNSRouting.upstreams(for: "host.corp.example", resolvers: NetworkDNS.configuration(from: current).resolvers).map(\.address), ["fe80::53%utun5"])
  }

  func testNetworkSwitchDropsOldObservationsAndSelectsNewDNS() {
    let network = FakeNetwork()
    let state = DaemonState(network: network)
    requireTrue(state.updatePolicies([.init(id: "a", domains: ["example.com"], blocked: false)]))
    let request = query("example.com")
    _ = state.finish(answer(request), query: request, host: "example.com", networkID: network.identifier)
    requireEqual(state.snapshot()["a"], ["93.184.216.34"])
    network.identifier = Data("hotspot".utf8)
    network.resolvers = [.init(servers: ["172.20.10.1"])]
    requireEqual(state.snapshot(), [:])
    requireEqual(DNSRouting.upstreams(for: "example.com", resolvers: network.resolvers).map(\.address), ["172.20.10.1"])
    let stale = state.finish(answer(request), query: request, host: "example.com", networkID: Data("wifi".utf8))
    requireEqual(stale[3] & 0xf, 2)
    requireEqual(state.snapshot(), [:])
  }

  func testLimitChangeDuringLookupAndSharedAddressIsolation() {
    let network = FakeNetwork()
    let state = DaemonState(network: network)
    requireTrue(state.updatePolicies([
      .init(id: "a", domains: ["example.com"], blocked: false),
      .init(id: "b", domains: ["other.example"], blocked: false),
    ]))
    let first = query("example.com")
    let second = query("other.example")
    _ = state.finish(answer(first), query: first, host: "example.com", networkID: network.identifier)
    _ = state.finish(answer(second), query: second, host: "other.example", networkID: network.identifier)
    requireTrue(state.updatePolicies([
      .init(id: "a", domains: ["example.com"], blocked: true),
      .init(id: "b", domains: ["other.example"], blocked: false),
    ]))
    requireEqual(state.finish(answer(first), query: first, host: "example.com", networkID: network.identifier)[3] & 0xf, 3)
    requireEqual(state.finish(answer(second), query: second, host: "other.example", networkID: network.identifier)[3] & 0xf, 0)
    requireFalse(state.isBlocked("notexample.com"))
    requireTrue(state.isBlocked("media.example.com"))
  }

  func testRouteChangesAreAcknowledgedOnlyAfterSuccessfulRegistration() {
    let network = FakeNetwork()
    let state = DaemonState(network: network)
    requireTrue(state.updatePolicies([.init(id: "a", domains: ["example.com"], blocked: true)]))
    network.acceptsChanges = false
    requireFalse(state.updatePolicies([]))
    requireTrue(state.isBlocked("example.com"))
    requireFalse(state.status().ok)
    network.acceptsChanges = true
    requireTrue(state.updatePolicies([]))
    requireEqual(network.domains, [])
    requireFalse(state.isBlocked("example.com"))
    requireNotEqual(state.status().instanceID, DaemonState(network: FakeNetwork()).status().instanceID)
  }

  func testCachesFlushOnlyWhenBlockedDomainsChange() {
    let network = FakeNetwork()
    let state = DaemonState(network: network)
    requireTrue(state.updatePolicies([.init(id: "a", domains: ["example.com"], blocked: false)]))
    requireEqual(network.flushes, 0)
    requireTrue(state.updatePolicies([.init(id: "a", domains: ["example.com"], blocked: true)]))
    requireEqual(network.flushes, 1)
    requireTrue(state.updatePolicies([.init(id: "a", domains: ["example.com"], blocked: true)]))
    requireEqual(network.flushes, 1)
    requireTrue(state.updatePolicies([.init(id: "a", domains: ["example.com"], blocked: false)]))
    requireEqual(network.flushes, 2)
  }

  func testLongestActuallyMatchingDomainWins() {
    let state = DaemonState(network: FakeNetwork())
    requireTrue(state.updatePolicies([
      .init(id: "a", domains: ["example.com", "unrelated.long.domain.example"], blocked: true),
      .init(id: "b", domains: ["allowed.example.com"], blocked: false),
    ]))
    requireFalse(state.isBlocked("allowed.example.com"))
    requireTrue(state.isBlocked("example.com"))
  }

  func testSplitDNSDoesNotFallBackToPublicResolver() {
    let resolvers: [DNSResolver] = [
      .init(servers: ["1.1.1.1"]),
      .init(servers: ["10.0.0.1", "10.0.0.2"], domains: ["corp.example"]),
      .init(servers: ["fd00::53"], domains: ["dev.corp.example"]),
    ]
    requireEqual(DNSRouting.upstreams(for: "host.dev.corp.example", resolvers: resolvers).map(\.address), ["fd00::53"])
    requireEqual(DNSRouting.upstreams(for: "host.corp.example", resolvers: resolvers).map(\.address), ["10.0.0.1", "10.0.0.2"])
    requireEqual(DNSRouting.upstreams(for: "notcorp.example", resolvers: resolvers).map(\.address), ["1.1.1.1"])
    requireEqual(DNSRouting.upstreams(for: "example.com", resolvers: []), [])
  }

  func testRealUDPForwardingAndServerFailureFallback() throws {
    let request = query("example.com")
    let failed = try StubDNS(response: DNSMessage.serverFailureResponse(for: request)!)
    let healthy = try StubDNS(response: answer(request))
    let network = FakeNetwork()
    network.resolvers = [
      .init(servers: ["127.0.0.1"], order: 1, port: failed.port),
      .init(servers: ["127.0.0.1"], order: 2, port: healthy.port),
    ]
    let state = DaemonState(network: network)
    requireTrue(state.updatePolicies([.init(id: "a", domains: ["example.com"], blocked: false)]))
    let proxy = try DNSProxy(state: state, port: 0)
    let result = proxy.resolve(request, tcp: false)
    requireEqual(DNSMessage.addresses(in: result), ["93.184.216.34"])
    requireEqual(state.snapshot()["a"], ["93.184.216.34"])
    requireTrue(failed.wait())
    requireTrue(healthy.wait())
  }

  func testTruncatedUDPUsesTCPAndTCPIngressUsesTCP() throws {
    let request = query("example.com")
    let server = try StubDNS(response: answer(request), truncateUDP: true)
    let network = FakeNetwork()
    network.resolvers = [.init(servers: ["127.0.0.1"], port: server.port)]
    let proxy = try DNSProxy(state: DaemonState(network: network), port: 0)
    requireEqual(DNSMessage.addresses(in: proxy.resolve(request, tcp: false)), ["93.184.216.34"])
    requireTrue(server.wait())
    let tcpServer = try StubDNS(response: answer(request), tcpOnly: true)
    network.resolvers = [.init(servers: ["127.0.0.1"], port: tcpServer.port)]
    requireEqual(DNSMessage.addresses(in: proxy.resolve(request, tcp: true)), ["93.184.216.34"])
    requireTrue(tcpServer.wait())
  }

  func testDNSFailureIsNotReportedAsSiteBlock() throws {
    let state = DaemonState(network: FakeNetwork())
    requireTrue(state.updatePolicies([.init(id: "a", domains: ["example.com"], blocked: true)]))
    let proxy = try DNSProxy(state: state, port: 0)
    requireEqual(proxy.resolve(query("example.com"), tcp: false)[3] & 0xf, 3)
    requireEqual(proxy.resolve(query("other.example"), tcp: false)[3] & 0xf, 2)
    requireEqual(proxy.resolve(query("other.example"), tcp: true)[3] & 0xf, 2)
  }
}

/// A loopback upstream on an ephemeral port; no system DNS changes or Internet traffic.
private final class StubDNS: @unchecked Sendable {
  let port: Int
  private let finished = DispatchSemaphore(value: 0)

  init(response: Data, truncateUDP: Bool = false, tcpOnly: Bool = false) throws {
    let udp = try DNSTransport.listener(type: SOCK_DGRAM, port: 0)
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(udp, $0, &length) }
    }
    port = Int(UInt16(bigEndian: address.sin_port))
    let tcp: Int32
    do { tcp = try DNSTransport.listener(type: SOCK_STREAM, port: port) }
    catch { close(udp); throw error }
    DispatchQueue.global().async { [self] in
      defer { close(udp); close(tcp); finished.signal() }
      if !tcpOnly {
        var item = pollfd(fd: udp, events: Int16(POLLIN), revents: 0)
        guard poll(&item, 1, 3_000) > 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var client = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &client) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udp, &buffer, buffer.count, 0, $0, &length) }
        }
        guard count > 0 else { return }
        let result = truncateUDP ? DNSMessage.truncatedResponse(for: Data(buffer.prefix(count)))! : response
        result.withUnsafeBytes { bytes in
          withUnsafePointer(to: &client) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              _ = sendto(udp, bytes.baseAddress, bytes.count, 0, $0, length)
            }
          }
        }
      }
      if truncateUDP || tcpOnly {
        var item = pollfd(fd: tcp, events: Int16(POLLIN), revents: 0)
        guard poll(&item, 1, 3_000) > 0 else { return }
        let client = accept(tcp, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        DNSTransport.configure(client)
        guard DNSTransport.readFrame(from: client, until: Date().addingTimeInterval(1)) != nil else { return }
        _ = DNSTransport.writeFrame(response, to: client, until: Date().addingTimeInterval(1))
      }
    }
  }

  func wait() -> Bool { finished.wait(timeout: .now() + 4) == .success }
}

private func requireTrue(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
  precondition(value(), "Expected true", file: file, line: line)
}
private func requireFalse(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
  precondition(!value(), "Expected false", file: file, line: line)
}
private func requireEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
  precondition(a == b, "Expected \(b), got \(a)", file: file, line: line)
}
private func requireNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
  precondition(a != b, "Expected different values", file: file, line: line)
}

@main
struct DNSServiceTestRunner {
  static func main() throws {
    let tests = DNSServiceTests()
    tests.testSystemConfigurationSnapshotFollowsPrimaryServiceAndExcludesOurRoute()
    tests.testNetworkSwitchDropsOldObservationsAndSelectsNewDNS()
    tests.testLimitChangeDuringLookupAndSharedAddressIsolation()
    tests.testRouteChangesAreAcknowledgedOnlyAfterSuccessfulRegistration()
    tests.testCachesFlushOnlyWhenBlockedDomainsChange()
    tests.testLongestActuallyMatchingDomainWins()
    tests.testSplitDNSDoesNotFallBackToPublicResolver()
    try tests.testDNSFailureIsNotReportedAsSiteBlock()
    try tests.testRealUDPForwardingAndServerFailureFallback()
    try tests.testTruncatedUDPUsesTCPAndTCPIngressUsesTCP()
    print("All DNS service regression tests passed.")
  }
}
