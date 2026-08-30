import Darwin
import Foundation

public enum DaemonClientError: LocalizedError {
  case unavailable
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .unavailable: return "The Web Time system service is not running."
    case .invalidResponse: return "The Web Time system service returned an invalid response."
    }
  }
}

public struct DaemonClient: Sendable {
  public init() {}

  public func send(_ command: DaemonCommand) throws -> DaemonStatus {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw DaemonClientError.unavailable }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
      socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(
      descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
      socklen_t(MemoryLayout.size(ofValue: timeout)))
    var noSignal: Int32 = 1
    setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
      socklen_t(MemoryLayout.size(ofValue: noSignal)))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = AppPaths.daemonSocket.utf8CString
    withUnsafeMutableBytes(of: &address.sun_path) { target in
      for (index, byte) in path.prefix(target.count).enumerated() {
        target[index] = UInt8(bitPattern: byte)
      }
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw DaemonClientError.unavailable }
    let request = try JSONEncoder().encode(command)
    guard sendAll(request, to: descriptor) else { throw DaemonClientError.unavailable }
    shutdown(descriptor, SHUT_WR)
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = recv(descriptor, &buffer, buffer.count, 0)
      if count <= 0 { break }
      response.append(contentsOf: buffer.prefix(Int(count)))
    }
    guard let status = try? JSONDecoder().decode(DaemonStatus.self, from: response) else {
      throw DaemonClientError.invalidResponse
    }
    return status
  }

  private func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.send(
          descriptor, baseAddress.advanced(by: offset), bytes.count - offset, 0)
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
  }
}
