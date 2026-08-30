import Foundation

public enum DNSMessage {
  public static func isStandardQuery(_ data: Data) -> Bool {
    guard data.count >= 17, data[2] & 0x80 == 0, data[2] & 0x78 == 0,
      readUInt16(data, 4) == 1
    else { return false }
    var offset = 12
    guard skipUncompressedName(data, offset: &offset), offset + 4 <= data.count else {
      return false
    }
    let queryType = readUInt16(data, offset)
    let queryClass = readUInt16(data, offset + 2)
    return queryType != 0 && queryClass == 1
  }

  public static func questionName(in data: Data) -> String? {
    guard data.count >= 12 else { return nil }
    var offset = 12
    var labels: [String] = []
    while offset < data.count {
      let length = Int(data[offset])
      offset += 1
      if length == 0 { return labels.joined(separator: ".") }
      guard length <= 63, offset + length <= data.count else { return nil }
      guard let label = String(data: data[offset..<(offset + length)], encoding: .utf8) else {
        return nil
      }
      labels.append(label)
      offset += length
    }
    return nil
  }

  public static func nxdomainResponse(for query: Data) -> Data? {
    guard query.count >= 12 else { return nil }
    var response = query
    // QR=1, preserve opcode/RD, set RA=1 and RCODE=3 (NXDOMAIN).
    response[2] = (query[2] & 0x79) | 0x80
    response[3] = (query[3] & 0xF0) | 0x83
    response[6] = 0
    response[7] = 0  // ANCOUNT
    response[8] = 0
    response[9] = 0  // NSCOUNT
    response[10] = 0
    response[11] = 0  // ARCOUNT
    return response
  }

  public static func isResponse(_ response: Data, to query: Data) -> Bool {
    guard response.count >= 12, query.count >= 12,
      response[0] == query[0], response[1] == query[1],
      response[2] & 0x80 == 0x80,
      let responseName = questionName(in: response),
      let queryName = questionName(in: query)
    else { return false }
    return responseName.caseInsensitiveCompare(queryName) == .orderedSame
  }

  /// Returns A and AAAA records anywhere in a DNS response, following compressed names.
  public static func addresses(in data: Data) -> [String] {
    guard data.count >= 12 else { return [] }
    let questionCount = Int(readUInt16(data, 4))
    let answerCount = Int(readUInt16(data, 6))
    var offset = 12
    for _ in 0..<questionCount {
      guard skipName(data, offset: &offset), offset + 4 <= data.count else { return [] }
      offset += 4
    }
    var result: [String] = []
    for _ in 0..<answerCount {
      guard skipName(data, offset: &offset), offset + 10 <= data.count else { break }
      let type = readUInt16(data, offset)
      let length = Int(readUInt16(data, offset + 8))
      offset += 10
      guard offset + length <= data.count else { break }
      if type == 1, length == 4 {
        result.append(data[offset..<(offset + 4)].map(String.init).joined(separator: "."))
      } else if type == 28, length == 16 {
        var groups: [String] = []
        for i in stride(from: offset, to: offset + 16, by: 2) {
          groups.append(String(format: "%x", (UInt16(data[i]) << 8) | UInt16(data[i + 1])))
        }
        result.append(groups.joined(separator: ":"))
      }
      offset += length
    }
    return result
  }

  private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
  }

  private static func skipName(_ data: Data, offset: inout Int) -> Bool {
    while offset < data.count {
      let length = Int(data[offset])
      if length & 0xC0 == 0xC0 {
        guard offset + 1 < data.count else { return false }
        offset += 2
        return true
      }
      offset += 1
      if length == 0 { return true }
      guard length <= 63, offset + length <= data.count else { return false }
      offset += length
    }
    return false
  }

  private static func skipUncompressedName(_ data: Data, offset: inout Int) -> Bool {
    while offset < data.count {
      let length = Int(data[offset])
      guard length & 0xC0 == 0 else { return false }
      offset += 1
      if length == 0 { return true }
      guard length <= 63, offset + length <= data.count else { return false }
      offset += length
    }
    return false
  }
}
