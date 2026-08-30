import Foundation

public enum SiteDomains {
  private static let knownServices: [(name: String, domains: [String])] = [
    ("YouTube", SiteConfiguration.youtube.domains),
    ("Instagram", ["instagram.com", "cdninstagram.com", "fbcdn.net"]),
    ("Facebook", ["facebook.com", "fbcdn.net", "fbsbx.com"]),
    ("TikTok", ["tiktok.com", "tiktokcdn.com", "tiktokv.com", "byteoversea.com", "ibytedtos.com"]),
    ("Reddit", ["reddit.com", "redd.it", "redditmedia.com", "redditstatic.com"]),
    ("X", ["x.com", "twitter.com", "twimg.com", "t.co"]),
    ("Twitch", ["twitch.tv", "ttvnw.net", "jtvnw.net"]),
    ("Netflix", ["netflix.com", "nflxvideo.net", "nflximg.net", "nflxso.net", "nflxext.com"]),
    ("Wikipedia", ["wikipedia.org", "wikimedia.org", "wikimediafoundation.org"]),
  ]

  public static func normalize(_ rawDomain: String) -> String {
    var value = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let url = URL(string: value), let host = url.host, value.contains("://") { value = host }
    return value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
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

  /// Adds well-known media/static domains that a user would not reasonably be expected to know.
  public static func expandedKnownDomains(_ domains: [String]) -> [String] {
    let normalized = domains.map(normalize).filter(isValid)
    guard let enteredPrimary = normalized.first else { return [] }
    var result = Set(normalized)
    let matchedService = knownServices.first { service in
      service.domains.contains(where: { host(enteredPrimary, matchesAny: [$0]) })
    }
    if let matchedService {
      result.formUnion(matchedService.domains)
    }
    let primary = matchedService?.domains.first ?? enteredPrimary
    return [primary] + result.filter { $0 != primary && isValid($0) }.sorted()
  }

  public static func suggestedName(for rawDomain: String) -> String? {
    let domain = normalize(rawDomain)
    return knownServices.first { service in
      service.domains.contains(where: { host(domain, matchesAny: [$0]) })
    }?.name
  }

  public static func fallbackName(for rawDomain: String) -> String {
    let domain = normalize(rawDomain)
    let labels = domain.split(separator: ".")
    let meaningful = labels.dropLast().last.map(String.init) ?? domain
    return meaningful.prefix(1).uppercased() + meaningful.dropFirst()
  }
}
