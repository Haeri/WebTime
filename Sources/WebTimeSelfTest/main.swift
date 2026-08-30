import Foundation
import WebTimeCore

if CommandLine.arguments.contains("--daemon-status") {
  do {
    let status = try DaemonClient().send(.status)
    let data = try JSONEncoder().encode(status)
    print(String(decoding: data, as: UTF8.self))
    exit(status.ok ? 0 : 1)
  } catch {
    FileHandle.standardError.write(Data("Daemon status failed: \(error)\n".utf8))
    exit(2)
  }
}

private var failures = 0
@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if condition() {
    print("✓ \(message)")
  } else {
    failures += 1
    print("✗ \(message)")
  }
}

private func dnsQuery(name: String) -> Data {
  var bytes: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
  for label in name.split(separator: ".") {
    bytes.append(UInt8(label.utf8.count))
    bytes.append(contentsOf: label.utf8)
  }
  bytes.append(contentsOf: [0, 0, 1, 0, 1])
  return Data(bytes)
}

let start = Date(timeIntervalSince1970: 1_700_000_000)
var controls = ControlsSession()
expect(!controls.isUnlocked(at: start), "administrative controls are locked by default")
controls.unlock(at: start, inactivityTimeout: 300)
expect(controls.isUnlocked(at: start.addingTimeInterval(299)), "typing challenge unlocks controls")
controls.recordInteraction(at: start.addingTimeInterval(200), inactivityTimeout: 300)
expect(
  controls.isUnlocked(at: start.addingTimeInterval(499)),
  "app interaction refreshes the inactivity deadline")
expect(
  !controls.isUnlocked(at: start.addingTimeInterval(501)),
  "controls relock after five minutes without interaction")
controls.lock()
expect(!controls.isUnlocked(at: start), "manual lock immediately closes controls")

var ledger = UsageLedger(now: start)
let limits: [String: TimeInterval] = ["youtube": 100, "instagram": 50]
expect(
  ledger.tick(at: start, activeSiteIDs: ["youtube"], limits: limits).isEmpty,
  "first timer sample establishes a baseline"
)
expect(
  ledger.tick(at: start.addingTimeInterval(5), activeSiteIDs: [], limits: limits).isEmpty,
  "idle time is not counted")
expect(
  ledger.tick(at: start.addingTimeInterval(15), activeSiteIDs: ["youtube"], limits: limits)[
    "youtube"] == 10,
  "active elapsed time is counted")
expect(
  ledger.tick(
    at: start.addingTimeInterval(100), activeSiteIDs: ["youtube", "instagram"], limits: limits)[
      "instagram"] == 30,
  "sleep or stalled samples are capped at 30 seconds")
expect(
  ledger.consumed(siteID: "youtube") == 40 && ledger.consumed(siteID: "instagram") == 30,
  "simultaneously active websites have independent counters")

var capped = UsageLedger(
  usage: DailyUsage(
    day: UsageLedger.dayKey(for: start), consumedBySite: ["youtube": 60, "instagram": 20]),
  now: start)
expect(capped.shouldBlock(siteID: "youtube", limit: 60), "one website reaching its limit blocks")
expect(
  !capped.shouldBlock(siteID: "instagram", limit: 60),
  "another website retains its independent allowance")

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(secondsFromGMT: 0)!
let midnight = ISO8601DateFormatter().date(from: "2026-08-30T23:59:50Z")!
var rollover = UsageLedger(
  usage: DailyUsage(day: "2026-08-30", consumedBySite: ["youtube": 500]), now: midnight,
  calendar: utc)
rollover.resetIfNeeded(at: midnight.addingTimeInterval(20))
expect(
  rollover.usage.day == "2026-08-31" && rollover.usage.consumedBySite.isEmpty,
  "usage resets at local calendar-day rollover")

expect(SiteDomains.host("youtube.com", matchesAny: ["youtube.com"]), "exact domain matches")
expect(
  SiteDomains.host("RR3---SN-ABC.googlevideo.com.", matchesAny: ["googlevideo.com"]),
  "nested CDN domain matches case-insensitively")
expect(
  !SiteDomains.host("notyoutube.com", matchesAny: ["youtube.com"]),
  "lookalike domain does not match")
expect(
  !SiteDomains.host("youtube.com.example.org", matchesAny: ["youtube.com"]),
  "suffix boundary is enforced")
expect(
  SiteDomains.normalize("https://WWW.Instagram.com/") == "www.instagram.com",
  "website URLs normalize to hostnames")
expect(
  SiteDomains.expandedKnownDomains(["instagram.com"]).contains("cdninstagram.com"),
  "known media domains are added automatically")

let configuration = LimiterConfiguration(
  sites: [.youtube], idleGraceSeconds: 20, controlsInactivitySeconds: 300)
let roundTrippedConfiguration = try! JSONDecoder().decode(
  LimiterConfiguration.self, from: JSONEncoder().encode(configuration))
expect(
  roundTrippedConfiguration == configuration,
  "website configuration survives persistence round-trip")
let usage = DailyUsage(
  day: "2026-08-30", consumedBySite: ["youtube": 123], lastSampleAt: start)
let roundTrippedUsage = try! JSONDecoder().decode(
  DailyUsage.self, from: JSONEncoder().encode(usage))
expect(roundTrippedUsage == usage, "per-site usage survives persistence round-trip")

let rankingSites = (1...7).map {
  SiteConfiguration(
    id: "site-\($0)", name: "Site \($0)", domains: ["site\($0).example"], dailyLimitSeconds: 60)
}
let rankedSites = SiteRanking.mostUsed(
  rankingSites,
  consumedBySite: [
    "site-1": 10, "site-2": 70, "site-3": 30, "site-4": 50, "site-5": 20, "site-6": 60,
    "site-7": 40,
  ],
  limit: 5)
expect(
  rankedSites.map(\.id) == ["site-2", "site-6", "site-4", "site-7", "site-3"],
  "menu ranking keeps only the five highest-usage websites in descending order")
let tieRank = SiteRanking.mostUsed(
  Array(rankingSites.prefix(3)), consumedBySite: ["site-1": 10, "site-2": 10, "site-3": 10],
  limit: 5)
expect(
  tieRank.map(\.id) == ["site-1", "site-2", "site-3"],
  "equal website usage preserves configured order")

var usageHistory = UsageHistory(days: ["2026-08-30": ["youtube": 120]])
let historySample = ISO8601DateFormatter().date(from: "2026-08-30T12:15:00Z")!
usageHistory.record(
  totals: ["youtube": 125], increments: ["youtube": 5], at: historySample, calendar: utc)
expect(
  usageHistory.hourly["2026-08-30"]?["12"]?["youtube"] == 5,
  "hourly website usage is recorded for the statistics chart")
for day in 1...405 {
  let key = String(format: "2025-%03d", day)
  usageHistory.days[key] = ["youtube": 1]
  usageHistory.hourly[key] = ["00": ["youtube": 1]]
}
usageHistory.trim(keepingRecentDays: 400)
expect(
  usageHistory.days.count == 400 && usageHistory.hourly.count <= 400,
  "statistics retention remains capped at 400 days")
let policyCommand = DaemonCommand.updatePolicies([
  DaemonSitePolicy(id: "instagram", domains: ["instagram.com"], blocked: true)
])
let decodedCommand = try! JSONDecoder().decode(
  DaemonCommand.self, from: JSONEncoder().encode(policyCommand))
if case .updatePolicies(let policies) = decodedCommand {
  expect(
    policies.first?.id == "instagram" && policies.first?.blocked == true,
    "per-site daemon policies round-trip")
} else {
  expect(false, "per-site daemon policies round-trip")
}
expect(
  DaemonPolicyValidator.errorMessage(for: [
    DaemonSitePolicy(id: "duplicate", domains: ["one.example"], blocked: false),
    DaemonSitePolicy(id: "duplicate", domains: ["two.example"], blocked: true),
  ]) != nil,
  "duplicate daemon policy identifiers are rejected")

let query = dnsQuery(name: "www.youtube.com")
expect(DNSMessage.isStandardQuery(query), "ordinary single-question DNS queries are accepted")
var responseAsQuery = query
responseAsQuery[2] |= 0x80
expect(!DNSMessage.isStandardQuery(responseAsQuery), "DNS responses are rejected at query ingress")
var compressedQuery = query
compressedQuery.replaceSubrange(12..<16, with: [0xC0, 0x0C])
expect(
  !DNSMessage.isStandardQuery(compressedQuery),
  "compressed or self-referential query names are rejected at ingress")
expect(DNSMessage.questionName(in: query) == "www.youtube.com", "DNS question name parses")
let denied = DNSMessage.nxdomainResponse(for: query)!
expect(
  denied[0] == query[0] && denied[1] == query[1] && denied[2] & 0x80 == 0x80
    && denied[3] & 0x0F == 3, "NXDOMAIN response keeps the transaction and sets response flags")
expect(DNSMessage.isResponse(denied, to: query), "matching DNS responses are accepted")
var unrelated = denied
unrelated[1] ^= 0x01
expect(!DNSMessage.isResponse(unrelated, to: query), "unrelated DNS responses are rejected")
var answer = dnsQuery(name: "youtube.com")
answer[2] = 0x81
answer[3] = 0x80
answer[6] = 0
answer[7] = 1
answer.append(contentsOf: [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 142, 250, 1, 190])
expect(DNSMessage.addresses(in: answer) == ["142.250.1.190"], "DNS IPv4 answer parses")
expect(
  NetworkAddressPolicy.isSafeToBlock("142.250.1.190"),
  "public delivery addresses are eligible for site blocking")
expect(
  !NetworkAddressPolicy.isSafeToBlock("192.168.1.1")
    && !NetworkAddressPolicy.isSafeToBlock(
      "1.1.1.1", protectedAddresses: ["1.1.1.1"]),
  "private and explicitly protected infrastructure addresses are never blocked")

let challenge = RecoveryChallenge.generate()
expect(challenge.split(separator: " ").count == 12, "recovery challenge contains 12 words")
expect(
  RecoveryChallenge.matches(typed: challenge, challenge: challenge),
  "exact one-time recovery challenge matches")
expect(
  !RecoveryChallenge.matches(typed: challenge + " extra", challenge: challenge),
  "different recovery challenge is rejected")

let nettop = "tcp4 192.168.1.2:50123<->142.250.1.190:443,en0,Established,1500,230\n"
expect(
  NetworkActivityDetector.parseNettop(nettop, matching: ["142.250.1.190"])["142.250.1.190"] == 1730,
  "nettop byte counters parse")
expect(
  NetworkActivityDetector.parseNettop(
    nettop, matchingBySite: ["youtube": ["142.250.1.190"], "instagram": ["31.13.70.1"]])[
      "youtube"] == 1730,
  "network byte counters are attributed per website")

let processNettop = """
  Google Chrome.998,,
  tcp4 192.168.1.2:50123<->142.250.1.190:443,en0,Established,1500,230
  Safari.402,,
  tcp4 192.168.1.2:50124<->31.13.70.1:443,en0,Established,900,100
  """
let processSnapshot = NetworkActivityDetector.parseNettopSnapshot(
  processNettop,
  matchingBySite: ["youtube": ["142.250.1.190"], "instagram": ["31.13.70.1"]])
expect(
  processSnapshot.processNamesBySite["youtube"] == ["Google Chrome"],
  "nettop ownership is attributed to the browser process")
expect(
  NetworkActivityDetector.matchesForeground(
    processSnapshot.processNamesBySite["youtube"], hints: ["chrome"]),
  "foreground browser traffic is eligible for counting")
expect(
  !NetworkActivityDetector.matchesForeground(
    processSnapshot.processNamesBySite["youtube"], hints: ["Safari"]),
  "background browser traffic is ignored")
expect(
  NetworkActivityDetector.selectSingleSite(
    trafficDeltas: ["youtube": 50_000, "instagram": 2_000], newlyActive: ["instagram"],
    current: "youtube", eligible: ["youtube", "instagram"],
    lastTrafficAtBySite: ["youtube": Date(), "instagram": Date()]) == "instagram",
  "a newly active website becomes the one usage bucket even beside background traffic")
expect(
  NetworkActivityDetector.selectSingleSite(
    trafficDeltas: [:], newlyActive: [], current: "instagram",
    eligible: ["youtube", "instagram"], lastTrafficAtBySite: [:]) == "instagram",
  "one current usage bucket is retained during the warm buffer")

let instagramDomains = SiteDomains.expandedKnownDomains(["instagram.com"])
expect(instagramDomains.first == "instagram.com", "primary website remains first for its favicon")
expect(
  instagramDomains.contains("cdninstagram.com") && instagramDomains.contains("fbcdn.net"),
  "known Instagram delivery domains are filled in")
expect(
  SiteDomains.suggestedName(for: "www.instagram.com") == "Instagram",
  "known website name is suggested automatically")

if failures > 0 {
  FileHandle.standardError.write(Data("\n\(failures) self-test(s) failed.\n".utf8))
  exit(1)
}
print("\nAll Web Time self-tests passed.")
