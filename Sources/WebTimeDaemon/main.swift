import Darwin
import Foundation
import WebTimeCore

private final class DaemonState: @unchecked Sendable {
  private static let maximumAddressesPerSite = 512
  private static let maximumAddressesTotal = 4_096
  private let lock = NSLock()
  private var policies: [String: DaemonSitePolicy] = [:]
  private var addressesBySite: [String: Set<String>] = [:]

  func snapshot() -> [String: [String]] {
    lock.lock()
    defer { lock.unlock() }
    return addressesBySite.mapValues { $0.sorted() }
  }

  func policy(matching host: String) -> DaemonSitePolicy? {
    lock.lock()
    defer { lock.unlock() }
    return policies.values
      .filter { SiteDomains.host(host, matchesAny: $0.domains) }
      .max { left, right in
        (left.domains.map(\.count).max() ?? 0) < (right.domains.map(\.count).max() ?? 0)
      }
  }

  func updatePolicies(_ newPolicies: [DaemonSitePolicy]) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    policies = newPolicies.reduce(into: [:]) { result, policy in result[policy.id] = policy }
    addressesBySite = addressesBySite.filter { policies[$0.key] != nil }
    return blockedAddressesLocked()
  }

  func learn(_ newAddresses: [String], for siteID: String) -> (changed: Bool, blocked: [String]) {
    lock.lock()
    defer { lock.unlock() }
    let before = addressesBySite[siteID, default: []].count
    let total = addressesBySite.values.reduce(0) { $0 + $1.count }
    let remaining = max(
      0, min(Self.maximumAddressesPerSite - before, Self.maximumAddressesTotal - total))
    addressesBySite[siteID, default: []].formUnion(newAddresses.prefix(remaining))
    return (addressesBySite[siteID, default: []].count != before, blockedAddressesLocked())
  }

  private func blockedAddressesLocked() -> [String] {
    let blockedIDs = Set(policies.values.filter(\.blocked).map(\.id))
    return blockedIDs.flatMap { addressesBySite[$0] ?? [] }.sorted()
  }
}

private enum PacketFilter {
  static let anchor = "local.web-time"

  static func update(blockedAddresses addresses: [String]) {
    if addresses.isEmpty {
      _ = run(["-a", anchor, "-F", "all"])
      return
    }
    _ = run(["-E"])
    let ipv4 = addresses.filter { $0.contains(".") }
    let ipv6 = addresses.filter { $0.contains(":") }
    var rules = ""
    if !ipv4.isEmpty {
      rules += "table <web_time_v4> persist { \(ipv4.joined(separator: ", ")) }\n"
      rules += "block drop quick inet proto { tcp udp } from any to <web_time_v4>\n"
    }
    if !ipv6.isEmpty {
      rules += "table <web_time_v6> persist { \(ipv6.joined(separator: ", ")) }\n"
      rules += "block drop quick inet6 proto { tcp udp } from any to <web_time_v6>\n"
    }
    _ = run(["-a", anchor, "-f", "-"], input: rules)
    // Terminate existing states so an already-open QUIC/TCP stream cannot coast past the limit.
    for address in addresses {
      let wildcard = address.contains(":") ? "::/0" : "0.0.0.0/0"
      _ = run(["-k", wildcard, "-k", address])
    }
  }

  @discardableResult
  private static func run(_ arguments: [String], input: String? = nil) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    if let input {
      let pipe = Pipe()
      process.standardInput = pipe
      do {
        try process.run()
        pipe.fileHandleForWriting.write(Data(input.utf8))
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
      } catch { return false }
    }
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch { return false }
  }
}

private final class DNSProxy: @unchecked Sendable {
  private let state: DaemonState
  private let upstream: String
  private let queue = DispatchQueue(
    label: "local.web-time.dns", qos: .userInitiated, attributes: .concurrent)
  private let capacity = DispatchSemaphore(value: 32)
  private let protectedAddresses: Set<String>

  init(state: DaemonState, upstream: String) {
    self.state = state
    self.upstream = upstream
    protectedAddresses = [upstream]
  }

  func run() throws -> Never {
    let server = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard server >= 0 else { throw POSIXError(.EIO) }
    var yes: Int32 = 1
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(53).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      close(server)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    while true {
      var buffer = [UInt8](repeating: 0, count: 4096)
      var client = sockaddr_storage()
      var clientLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let count = withUnsafeMutablePointer(to: &client) { clientPointer in
        clientPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
          recvfrom(server, &buffer, buffer.count, 0, pointer, &clientLength)
        }
      }
      guard count > 0 else { continue }
      let query = Data(buffer.prefix(Int(count)))
      guard DNSMessage.isStandardQuery(query), capacity.wait(timeout: .now()) == .success else {
        continue
      }
      let clientCopy = client
      let clientLengthCopy = clientLength
      queue.async { [self] in
        defer { capacity.signal() }
        let host = DNSMessage.questionName(in: query) ?? ""
        let policy = state.policy(matching: host)
        let response: Data?
        if policy?.blocked == true {
          response = DNSMessage.nxdomainResponse(for: query)
        } else {
          response = forward(query)
          if let policy, let response {
            let addresses = DNSMessage.addresses(in: response).filter {
              NetworkAddressPolicy.isSafeToBlock($0, protectedAddresses: protectedAddresses)
            }
            let learned = state.learn(addresses, for: policy.id)
            if learned.changed && policy.blocked {
              PacketFilter.update(blockedAddresses: learned.blocked)
            }
          }
        }
        guard let response else { return }
        var destination = clientCopy
        response.withUnsafeBytes { bytes in
          withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
              _ = sendto(server, bytes.baseAddress, bytes.count, 0, pointer, clientLengthCopy)
            }
          }
        }
      }
    }
  }

  private func forward(_ query: Data) -> Data? {
    let client = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard client >= 0 else { return nil }
    defer { close(client) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(
      client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var destination = sockaddr_in()
    destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    destination.sin_family = sa_family_t(AF_INET)
    destination.sin_port = in_port_t(53).bigEndian
    guard inet_pton(AF_INET, upstream, &destination.sin_addr) == 1 else { return nil }
    let connected = withUnsafePointer(to: &destination) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        connect(client, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { return nil }
    let sent = query.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
    guard sent == query.count else { return nil }
    var buffer = [UInt8](repeating: 0, count: 65_535)
    let count = recv(client, &buffer, buffer.count, 0)
    guard count > 0 else { return nil }
    let response = Data(buffer.prefix(Int(count)))
    return DNSMessage.isResponse(response, to: query) ? response : nil
  }
}

private final class ControlServer: @unchecked Sendable {
  private let state: DaemonState
  init(state: DaemonState) { self.state = state }

  func start() {
    DispatchQueue(label: "local.web-time.control", qos: .userInitiated).async { [self] in run() }
  }

  private func run() {
    unlink(AppPaths.daemonSocket)
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { return }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = AppPaths.daemonSocket.utf8CString
    withUnsafeMutableBytes(of: &address.sun_path) { target in
      for (index, byte) in path.prefix(target.count).enumerated() {
        target[index] = UInt8(bitPattern: byte)
      }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      close(server)
      return
    }
    chown(AppPaths.daemonSocket, 0, 20)  // root:staff
    chmod(AppPaths.daemonSocket, 0o660)
    guard listen(server, 8) == 0 else {
      close(server)
      return
    }
    while true {
      let client = accept(server, nil, nil)
      guard client >= 0 else { continue }
      guard isAuthorized(client) else {
        close(client)
        continue
      }
      var timeout = timeval(tv_sec: 2, tv_usec: 0)
      setsockopt(
        client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
      setsockopt(
        client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
      var noSignal: Int32 = 1
      setsockopt(
        client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout.size(ofValue: noSignal)))
      handle(client)
      close(client)
    }
  }

  private func isAuthorized(_ client: Int32) -> Bool {
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(client, &peerUID, &peerGID) == 0 else { return false }
    if peerUID == 0 { return true }
    var console = stat()
    guard lstat("/dev/console", &console) == 0 else { return false }
    return peerUID == console.st_uid
  }

  private func handle(_ client: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16_384)
    let count = recv(client, &buffer, buffer.count, 0)
    guard count > 0,
      let command = try? JSONDecoder().decode(
        DaemonCommand.self, from: Data(buffer.prefix(Int(count))))
    else { return }
    let response: DaemonStatus
    switch command {
    case .status:
      response = DaemonStatus(ok: true, learnedAddressesBySite: state.snapshot())
    case .updatePolicies(let policies):
      if let message = DaemonPolicyValidator.errorMessage(for: policies) {
        response = DaemonStatus(
          ok: false, learnedAddressesBySite: state.snapshot(), message: message)
        break
      }
      let addresses = state.updatePolicies(policies)
      PacketFilter.update(blockedAddresses: addresses)
      response = DaemonStatus(ok: true, learnedAddressesBySite: state.snapshot())
    }
    guard let data = try? JSONEncoder().encode(response) else { return }
    _ = sendAll(data, to: client)
  }

  private func sendAll(_ data: Data, to client: Int32) -> Bool {
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
      var offset = 0
      while offset < bytes.count {
        let count = send(client, baseAddress.advanced(by: offset), bytes.count - offset, 0)
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
  }
}

guard geteuid() == 0 else {
  FileHandle.standardError.write(Data("webtimed must run as root\n".utf8))
  exit(77)
}
private let arguments = CommandLine.arguments
private let configuredUpstream = arguments.first(where: { $0.hasPrefix("--upstream=") })?
  .split(separator: "=", maxSplits: 1).last.map(String.init)
private let upstreamFile = arguments.first(where: { $0.hasPrefix("--upstream-file=") })?
  .split(separator: "=", maxSplits: 1).last.map(String.init)
private let upstreamFromFile = upstreamFile.flatMap { path in
  (try? String(contentsOfFile: path, encoding: .utf8))?
    .split(whereSeparator: \.isWhitespace).first.map(String.init)
}
private let upstream = upstreamFromFile ?? configuredUpstream ?? "1.1.1.1"
private let state = DaemonState()
ControlServer(state: state).start()
do { try DNSProxy(state: state, upstream: upstream).run() } catch {
  FileHandle.standardError.write(Data("webtimed failed: \(error)\n".utf8))
  exit(1)
}
