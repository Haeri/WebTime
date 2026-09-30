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
    return queryType != 0 && queryClass == 1 && questionName(in: data) != nil
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
    errorResponse(for: query, code: 3)
  }

  public static func serverFailureResponse(for query: Data) -> Data? {
    errorResponse(for: query, code: 2)
  }

  public static func truncatedResponse(for query: Data) -> Data? {
    guard var response = errorResponse(for: query, code: 0) else { return nil }
    response[2] |= 0x02
    return response
  }

  private static func questionEnd(_ data: Data) -> Int? {
    guard data.count >= 12, readUInt16(data, 4) == 1 else { return nil }
    var offset = 12
    guard skipUncompressedName(data, offset: &offset), offset + 4 <= data.count else { return nil }
    return offset + 4
  }

  private static func errorResponse(for query: Data, code: UInt8) -> Data? {
    guard let end = questionEnd(query) else { return nil }
    // Copy only the question: copying EDNS bytes while clearing ARCOUNT is malformed.
    var response = Data(query.prefix(end))
    response[2] = (query[2] & 0x01) | 0x80
    response[3] = 0x80 | code
    for offset in 6..<12 { response[offset] = 0 }
    return response
  }

  public static func isResponse(_ response: Data, to query: Data) -> Bool {
    guard let responseEnd = questionEnd(response), let queryEnd = questionEnd(query),
      response[0] == query[0], response[1] == query[1],
      response[2] & 0xf8 == 0x80,
      let responseName = questionName(in: response), let queryName = questionName(in: query),
      response.suffix(from: responseEnd - 4).prefix(4)
        == query.suffix(from: queryEnd - 4).prefix(4) else { return false }
    return responseName.caseInsensitiveCompare(queryName) == .orderedSame
  }

  public static func udpPayloadSize(_ query: Data) -> Int {
    guard let end = questionEnd(query) else { return 512 }
    var offset = end
    for _ in 0..<Int(readUInt16(query, 10)) {
      guard skipName(query, offset: &offset), offset + 10 <= query.count else { return 512 }
      if readUInt16(query, offset) == 41 {
        return max(512, min(4_096, Int(readUInt16(query, offset + 2))))
      }
      offset += 10 + Int(readUInt16(query, offset + 8))
    }
    return 512
  }

  /// Bound positive cache lifetimes so a new lookup sees a changed allowance soon.
  /// DNSSEC records are left untouched: rewriting signed TTLs can invalidate validation.
  public static func limitingAnswerTTL(_ data: Data, to maximum: UInt32) -> Data {
    guard let end = questionEnd(data) else { return data }
    var offset = end
    var ttlOffsets: [Int] = []
    for _ in 0..<Int(readUInt16(data, 6)) {
      guard skipName(data, offset: &offset), offset + 10 <= data.count else { return data }
      let type = readUInt16(data, offset)
      if type == 46 { return data } // RRSIG
      ttlOffsets.append(offset + 4)
      let length = Int(readUInt16(data, offset + 8))
      offset += 10 + length
      guard offset <= data.count else { return data }
    }
    var response = data
    for offset in ttlOffsets {
      let ttl = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[offset + $1]) }
      let limited = min(ttl, maximum)
      for index in 0..<4 { response[offset + index] = UInt8((limited >> (24 - index * 8)) & 0xff) }
    }
    return response
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
