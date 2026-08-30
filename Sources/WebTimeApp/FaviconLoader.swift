import AppKit
import Foundation
import WebTimeCore

@MainActor
final class FaviconLoader {
  private static let retryDelay: TimeInterval = 60
  private var images: [String: NSImage] = [:]
  private var requestsInFlight = Set<String>()
  private var retryAfter: [String: Date] = [:]
  private let directory: URL?
  private let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 12
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    session = URLSession(configuration: configuration)
    directory = try? AppPaths.supportDirectory().appendingPathComponent(
      "Favicons", isDirectory: true)
    if let directory {
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
  }

  func image(for site: SiteConfiguration, onUpdate: @escaping @MainActor () -> Void) -> NSImage? {
    let key = cacheKey(for: site)
    if let image = images[key] { return image }
    let file = cacheFile(for: key)
    if let file, let image = NSImage(contentsOf: file) {
      images[key] = image
      return image
    }
    requestImage(for: site, key: key, file: file, onUpdate: onUpdate)
    return nil
  }

  func prefetch(for site: SiteConfiguration, onUpdate: @escaping @MainActor () -> Void) {
    _ = image(for: site, onUpdate: onUpdate)
  }

  private func requestImage(
    for site: SiteConfiguration, key: String, file: URL?,
    onUpdate: @escaping @MainActor () -> Void
  ) {
    guard !requestsInFlight.contains(key), SiteDomains.isValid(site.primaryDomain) else { return }
    if let retryDate = retryAfter[key], retryDate > Date() { return }
    requestsInFlight.insert(key)
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { requestsInFlight.remove(key) }
      for url in await faviconCandidates(for: site.primaryDomain) {
        do {
          let (data, response) = try await session.data(from: url)
          guard (response as? HTTPURLResponse)?.statusCode ?? 500 < 400,
            response.url?.scheme == "https",
            data.count <= 1_000_000, let image = NSImage(data: data)
          else { continue }
          images[key] = image
          retryAfter.removeValue(forKey: key)
          if let file {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes(
              [.posixPermissions: 0o600], ofItemAtPath: file.path)
          }
          onUpdate()
          return
        } catch { continue }
      }
      retryAfter[key] = Date().addingTimeInterval(Self.retryDelay)
    }
  }

  private func cacheKey(for site: SiteConfiguration) -> String {
    site.primaryDomain.replacingOccurrences(of: ".", with: "_")
  }

  private func cacheFile(for key: String) -> URL? {
    directory?.appendingPathComponent(key).appendingPathExtension("ico")
  }

  private func faviconCandidates(for domain: String) async -> [URL] {
    guard let homepage = URL(string: "https://\(domain)/") else { return [] }
    var candidates: [URL] = []
    do {
      let (data, response) = try await session.data(from: homepage)
      if (response as? HTTPURLResponse)?.statusCode ?? 500 < 400, data.count <= 1_000_000,
        response.url?.scheme == "https", let html = String(data: data, encoding: .utf8)
      {
        candidates.append(contentsOf: Self.iconURLs(in: html, relativeTo: response.url ?? homepage))
      }
    } catch {}
    candidates.append(homepage.appendingPathComponent("favicon.ico"))
    var seen = Set<String>()
    return candidates.filter { url in
      guard url.scheme == "https" else { return false }
      return seen.insert(url.absoluteString).inserted
    }
  }

  private static func iconURLs(in html: String, relativeTo baseURL: URL) -> [URL] {
    guard
      let tags = try? NSRegularExpression(
        pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    else { return [] }
    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    return tags.matches(in: html, range: range).compactMap { match in
      guard let tagRange = Range(match.range, in: html) else { return nil }
      let tag = String(html[tagRange])
      guard let relationship = attribute("rel", in: tag)?.lowercased(),
        relationship.split(whereSeparator: \Character.isWhitespace).contains(where: {
          $0 == "icon" || $0 == "shortcut" || $0 == "apple-touch-icon"
        }),
        let href = attribute("href", in: tag), !href.isEmpty
      else { return nil }
      return URL(string: href, relativeTo: baseURL)?.absoluteURL
    }
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    let pattern =
      #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*([\"'])(.*?)\1"#
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
      let match = expression.firstMatch(
        in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)),
      let valueRange = Range(match.range(at: 2), in: tag)
    else { return nil }
    return String(tag[valueRange])
  }
}
