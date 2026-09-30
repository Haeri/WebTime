import Darwin
import Foundation
import WebTimeCore

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
      response = state.status()
    case .updatePolicies(let policies):
      if let message = DaemonPolicyValidator.errorMessage(for: policies) {
        response = DaemonStatus(
          ok: false, learnedAddressesBySite: state.snapshot(), message: message)
        break
      }
      if state.updatePolicies(policies) {
        response = state.status()
      } else {
        response = DaemonStatus(ok: false, message: "Could not register website DNS routes.")
      }
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
do {
  let state = DaemonState(network: try NetworkDNS())
  // Bind both listeners before accepting policies that publish DNS routes.
  let proxy = try DNSProxy(state: state)
  ControlServer(state: state).start()
  proxy.run()
} catch {
  FileHandle.standardError.write(Data("webtimed failed: \(error)\n".utf8))
  exit(1)
}
