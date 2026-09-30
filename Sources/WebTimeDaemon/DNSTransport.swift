import Darwin
import Foundation
import WebTimeCore

enum DNSTransport {
  static func listener(type: Int32, port: Int) throws -> Int32 {
    let descriptor = socket(AF_INET, type, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    var yes: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0, type != SOCK_STREAM || listen(descriptor, 32) == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      close(descriptor)
      throw error
    }
    return descriptor
  }

  static func exchange(_ query: Data, server: DNSUpstream, tcp: Bool) -> Data? {
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = tcp ? SOCK_STREAM : SOCK_DGRAM
    var address: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(server.address, String(server.port), &hints, &address) == 0, let address else { return nil }
    defer { freeaddrinfo(address) }
    let descriptor = socket(address.pointee.ai_family, hints.ai_socktype, 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    configure(descriptor)
    let deadline = Date().addingTimeInterval(1)
    let result = connect(descriptor, address.pointee.ai_addr, address.pointee.ai_addrlen)
    if result != 0 {
      guard errno == EINPROGRESS, ready(descriptor, event: Int16(POLLOUT), until: deadline) else { return nil }
      var error: Int32 = 0
      var size = socklen_t(MemoryLayout.size(ofValue: error))
      guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return nil }
    }
    if tcp {
      guard writeFrame(query, to: descriptor, until: deadline),
        let response = readFrame(from: descriptor, until: deadline),
        DNSMessage.isResponse(response, to: query) else { return nil }
      return response
    }
    guard query.withUnsafeBytes({ send(descriptor, $0.baseAddress, $0.count, 0) }) == query.count,
      ready(descriptor, event: Int16(POLLIN), until: deadline) else { return nil }
    var buffer = [UInt8](repeating: 0, count: 65_535)
    let count = recv(descriptor, &buffer, buffer.count, 0)
    guard count > 0 else { return nil }
    let response = Data(buffer.prefix(Int(count)))
    return DNSMessage.isResponse(response, to: query) ? response : nil
  }

  static func configure(_ descriptor: Int32) {
    _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
    var yes: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
  }

  static func readFrame(from descriptor: Int32, until deadline: Date) -> Data? {
    guard let header = read(2, from: descriptor, until: deadline) else { return nil }
    let length = Int(header[0]) << 8 | Int(header[1])
    guard length >= 12 else { return nil }
    return read(length, from: descriptor, until: deadline)
  }

  static func writeFrame(_ data: Data, to descriptor: Int32, until deadline: Date) -> Bool {
    guard data.count <= 65_535 else { return false }
    let frame = Data([UInt8(data.count >> 8), UInt8(data.count & 0xff)]) + data
    return frame.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        guard ready(descriptor, event: Int16(POLLOUT), until: deadline) else { return false }
        let count = send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
        if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
        guard count > 0 else { return false }
        offset += count
      }
      return true
    }
  }

  private static func read(_ length: Int, from descriptor: Int32, until deadline: Date) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: length)
    while data.count < length {
      guard ready(descriptor, event: Int16(POLLIN), until: deadline) else { return nil }
      let count = recv(descriptor, &buffer, length - data.count, 0)
      if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
      guard count > 0 else { return nil }
      data.append(contentsOf: buffer.prefix(Int(count)))
    }
    return data
  }

  private static func ready(_ descriptor: Int32, event: Int16, until deadline: Date) -> Bool {
    while true {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { return false }
      var item = pollfd(fd: descriptor, events: event, revents: 0)
      let result = poll(&item, 1, Int32(min(remaining * 1_000, 10_000)))
      if result < 0 && errno == EINTR { continue }
      return result > 0 && item.revents & event != 0
    }
  }
}
