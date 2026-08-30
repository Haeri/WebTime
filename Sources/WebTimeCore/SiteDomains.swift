import Foundation

public enum SiteDomains {
  public static func normalize(_ rawDomain: String) -> String {
    var value = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let url = URL(string: value), let host = url.host, value.contains("://") { value = host }
    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    if value.hasPrefix("www.") { value.removeFirst(4) }
    return value
  }

  public static func isValid(_ rawDomain: String) -> Bool {
    let domain = normalize(rawDomain)
    guard domain.contains("."), domain.count <= 253 else { return false }
    return domain.split(separator: ".").allSatisfy { label in
      !label.isEmpty && label.count <= 63
        && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        && label.first != "-" && label.last != "-"
    }
  }

  public static func host(_ rawHost: String, matchesAny domains: [String]) -> Bool {
    let host = normalize(rawHost)
    return domains.contains { rawDomain in
      let domain = normalize(rawDomain)
      return host == domain || host.hasSuffix("." + domain)
    }
  }

  public static func normalizedUnique(_ domains: [String]) -> [String] {
    var seen = Set<String>()
    return domains.map(normalize).filter { isValid($0) && seen.insert($0).inserted }
  }

  public static func fallbackName(for rawDomain: String) -> String {
    let domain = normalize(rawDomain)
    let meaningful = domain.split(separator: ".").first.map(String.init) ?? domain
    return meaningful.prefix(1).uppercased() + meaningful.dropFirst()
  }
}
