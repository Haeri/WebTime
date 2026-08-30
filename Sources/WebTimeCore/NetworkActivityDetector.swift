import Foundation

public struct SiteNetworkSnapshot: Equatable, Sendable {
  public var totalsBySite: [String: Int64]
  public var processNamesBySite: [String: Set<String>]
}

public final class NetworkActivityDetector: @unchecked Sendable {
  private var previousTotalsBySite: [String: Int64] = [:]
  private var lastTrafficAtBySite: [String: Date] = [:]
  private var selectedSiteID: String?
  private let lock = NSLock()

  public init() {}

  public func sample(
    addressesBySite: [String: [String]], idleGrace: TimeInterval,
    foregroundProcessHints: [String] = [], now: Date = Date()
  ) -> String? {
    guard addressesBySite.values.contains(where: { !$0.isEmpty }) else { return nil }
    let output = nettopOutput()
    let snapshot = Self.parseNettopSnapshot(output, matchingBySite: addressesBySite)
    let totals = snapshot.totalsBySite
    lock.lock()
    defer { lock.unlock() }

    let previouslyWarm = Set(
      lastTrafficAtBySite.compactMap { siteID, date in
        now.timeIntervalSince(date) <= idleGrace ? siteID : nil
      })
    var trafficDeltas: [String: Int64] = [:]
    var newlyActive = Set<String>()
    for (siteID, value) in totals {
      let delta = value - (previousTotalsBySite[siteID] ?? value)
      guard delta > 0,
        Self.matchesForeground(
          snapshot.processNamesBySite[siteID], hints: foregroundProcessHints)
      else { continue }
      trafficDeltas[siteID] = delta
      if !previouslyWarm.contains(siteID) { newlyActive.insert(siteID) }
      lastTrafficAtBySite[siteID] = now
    }
    if !totals.isEmpty { previousTotalsBySite = totals }

    let eligible = Set(
      lastTrafficAtBySite.compactMap { siteID, date in
        now.timeIntervalSince(date) <= idleGrace
          && Self.matchesForeground(
            snapshot.processNamesBySite[siteID], hints: foregroundProcessHints)
          ? siteID : nil
      })
    selectedSiteID = Self.selectSingleSite(
      trafficDeltas: trafficDeltas, newlyActive: newlyActive, current: selectedSiteID,
      eligible: eligible, lastTrafficAtBySite: lastTrafficAtBySite)
    guard let selectedSiteID, eligible.contains(selectedSiteID) else { return nil }
    return selectedSiteID
  }

  public static func parseNettopSnapshot(
    _ output: String, matchingBySite addressesBySite: [String: [String]]
  ) -> SiteNetworkSnapshot {
    var result: [String: Int64] = [:]
    var processes: [String: Set<String>] = [:]
    var currentProcess = ""
    for line in output.split(whereSeparator: \.isNewline).map(String.init) {
      let firstField = String(line.split(separator: ",", maxSplits: 1).first ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = firstField.lowercased()
      let isSocket =
        lower.hasPrefix("tcp4 ") || lower.hasPrefix("tcp6 ")
        || lower.hasPrefix("udp4 ") || lower.hasPrefix("udp6 ")
      if !isSocket {
        if !firstField.isEmpty { currentProcess = processName(from: firstField) }
        continue
      }
      let values = line.split(separator: ",").compactMap {
        Int64($0.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      guard !values.isEmpty else { continue }
      for (siteID, addresses) in addressesBySite
      where addresses.contains(where: { line.contains($0) }) {
        result[siteID, default: 0] += values.reduce(0, +)
        if !currentProcess.isEmpty { processes[siteID, default: []].insert(currentProcess) }
      }
    }
    return SiteNetworkSnapshot(totalsBySite: result, processNamesBySite: processes)
  }

  public static func matchesForeground(_ processNames: Set<String>?, hints: [String]) -> Bool {
    guard !hints.isEmpty, let processNames, !processNames.isEmpty else { return true }
    return processNames.contains { processName in
      hints.contains { hint in
        processName.localizedCaseInsensitiveContains(hint)
          || hint.localizedCaseInsensitiveContains(processName)
      }
    }
  }

  public static func selectSingleSite(
    trafficDeltas: [String: Int64], newlyActive: Set<String>, current: String?,
    eligible: Set<String>, lastTrafficAtBySite: [String: Date]
  ) -> String? {
    let preferredDeltas =
      newlyActive.isEmpty
      ? trafficDeltas : trafficDeltas.filter { newlyActive.contains($0.key) }
    if let winner = preferredDeltas.sorted(by: { left, right in
      left.value == right.value ? left.key < right.key : left.value > right.value
    }).first?.key {
      return winner
    }
    if let current, eligible.contains(current) { return current }
    return eligible.sorted { left, right in
      let leftDate = lastTrafficAtBySite[left] ?? .distantPast
      let rightDate = lastTrafficAtBySite[right] ?? .distantPast
      return leftDate == rightDate ? left < right : leftDate > rightDate
    }.first
  }

  private static func processName(from firstField: String) -> String {
    let parts = firstField.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1, parts.last?.allSatisfy(\.isNumber) == true else {
      return firstField
    }
    return parts.dropLast().joined(separator: ".")
  }

  private func nettopOutput() -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
    process.arguments = ["-n", "-x", "-L", "1", "-J", "bytes_in,bytes_out"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return "" }
      return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    } catch { return "" }
  }
}
