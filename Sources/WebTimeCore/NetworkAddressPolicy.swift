import Darwin
import Foundation

public enum NetworkAddressPolicy {
  public static func isSafeToBlock(
    _ address: String, protectedAddresses: Set<String> = []
  ) -> Bool {
    guard !protectedAddresses.contains(address) else { return false }

    var ipv4 = in_addr()
    if inet_pton(AF_INET, address, &ipv4) == 1 {
      let value = UInt32(bigEndian: ipv4.s_addr)
      let first = UInt8((value >> 24) & 0xff)
      let second = UInt8((value >> 16) & 0xff)
      if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
      if first == 100 && (64...127).contains(second) { return false }
      if first == 169 && second == 254 { return false }
      if first == 172 && (16...31).contains(second) { return false }
      if first == 192 && (second == 0 || second == 168) { return false }
      if first == 198 && (second == 18 || second == 19) { return false }
      return true
    }

    var ipv6 = in6_addr()
    if inet_pton(AF_INET6, address, &ipv6) == 1 {
      let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
      let isUnspecified = bytes.allSatisfy { $0 == 0 }
      let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
      let isUniqueLocal = bytes[0] & 0xfe == 0xfc
      let isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
      let isMulticast = bytes[0] == 0xff
      return !(isUnspecified || isLoopback || isUniqueLocal || isLinkLocal || isMulticast)
    }
    return false
  }
}
