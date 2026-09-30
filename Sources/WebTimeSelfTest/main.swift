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
let limits: [String: TimeInterval] = ["site-a": 100, "site-b": 50]
expect(
  ledger.tick(at: start, activeSiteID: "site-a", limits: limits) == nil,
  "first timer sample establishes a baseline"
)
expect(
  ledger.tick(at: start.addingTimeInterval(5), activeSiteID: nil, limits: limits) == nil,
  "idle time is not counted")
expect(
  ledger.tick(at: start.addingTimeInterval(15), activeSiteID: "site-a", limits: limits)?.seconds
    == 10,
  "active elapsed time is counted")
expect(
  ledger.tick(
    at: start.addingTimeInterval(100), activeSiteID: "site-b", limits: limits)?.seconds == 30,
  "sleep or stalled samples are capped at 30 seconds")
expect(
  ledger.consumed(siteID: "site-a") == 10 && ledger.consumed(siteID: "site-b") == 30,
  "switching websites only advances the selected counter")

var capped = UsageLedger(
  usage: DailyUsage(
    day: UsageLedger.dayKey(for: start), consumedBySite: ["site-a": 60, "site-b": 20]),
  now: start)
expect(capped.shouldBlock(siteID: "site-a", limit: 60), "one website reaching its limit blocks")
expect(
  !capped.shouldBlock(siteID: "site-b", limit: 60),
  "another website retains its independent allowance")

var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(secondsFromGMT: 0)!
let midnight = ISO8601DateFormatter().date(from: "2026-08-30T23:59:50Z")!
var rollover = UsageLedger(
  usage: DailyUsage(day: "2026-08-30", consumedBySite: ["site-a": 500]), now: midnight,
  calendar: utc)
rollover.resetIfNeeded(at: midnight.addingTimeInterval(20))
expect(
  rollover.usage.day == "2026-08-31" && rollover.usage.consumedBySite.isEmpty,
  "usage resets at local calendar-day rollover")
expect(
  !rollover.shouldBlock(siteID: "site-a", limit: 500),
  "day rollover re-enables a website that exhausted yesterday's allowance")

var allowanceExtensions = AllowanceExtensionState()
allowanceExtensions.grant(siteID: "site-a")
expect(
  allowanceExtensions.additionalAllowance(siteID: "site-a") == 15 * 60,
  "snooze grants 15 minutes of additional allowance")
expect(
  allowanceExtensions.effectiveLimit(siteID: "site-a", baseLimit: 60) == 16 * 60,
  "snooze extends the website's effective limit")
var snoozedLedger = UsageLedger(
  usage: DailyUsage(
    day: UsageLedger.dayKey(for: start), consumedBySite: ["site-a": 60], lastSampleAt: start),
  now: start)
_ = snoozedLedger.tick(
  at: start.addingTimeInterval(5), activeSiteID: "site-a",
  limits: [
    "site-a": allowanceExtensions.effectiveLimit(siteID: "site-a", baseLimit: 60)
  ])
expect(
  snoozedLedger.consumed(siteID: "site-a") == 65,
  "foreground usage during a snooze remains visible in statistics")
expect(
  !snoozedLedger.shouldBlock(
    siteID: "site-a",
    limit: allowanceExtensions.effectiveLimit(siteID: "site-a", baseLimit: 60)),
  "a website remains available until its added allowance is consumed")

expect(SiteDomains.host("example.com", matchesAny: ["example.com"]), "exact domain matches")
expect(
  SiteDomains.host("MEDIA.Example.com.", matchesAny: ["example.com"]),
  "subdomain matches case-insensitively")
expect(
  !SiteDomains.host("notexample.com", matchesAny: ["example.com"]),
  "lookalike domain does not match")
expect(
  !SiteDomains.host("example.com.example.org", matchesAny: ["example.com"]),
  "suffix boundary is enforced")
expect(
  SiteDomains.normalize("https://WWW.Example.com/") == "example.com",
  "website URLs normalize to their base hostname")
expect(
  SiteDomains.normalizedUnique([
    "https://www.example.com/", "example.com", "media.example.net",
  ]) == ["example.com", "media.example.net"],
  "only explicit domains are normalized and deduplicated")

let sampleSite = SiteConfiguration(
  id: "site-a", name: "Example", domains: ["example.com"], dailyLimitSeconds: 3_600)
let configuration = LimiterConfiguration(
  sites: [sampleSite], idleGraceSeconds: 20, controlsInactivitySeconds: 300)
let roundTrippedConfiguration = try! JSONDecoder().decode(
  LimiterConfiguration.self, from: JSONEncoder().encode(configuration))
expect(
  roundTrippedConfiguration == configuration,
  "website configuration survives persistence round-trip")
expect(LimiterConfiguration().sites.isEmpty, "new configurations contain no preprogrammed websites")
let usage = DailyUsage(
  day: "2026-08-30", consumedBySite: ["site-a": 123], lastSampleAt: start)
let roundTrippedUsage = try! JSONDecoder().decode(
  DailyUsage.self, from: JSONEncoder().encode(usage))
expect(roundTrippedUsage == usage, "per-site usage survives persistence round-trip")
expect(
  DurationText.compact(3_660) == "1h 1m" && DurationText.compact(7_200) == "2h",
  "durations use one shared compact format")

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

var usageHistory = UsageHistory(days: ["2026-08-30": ["site-a": 120]])
let historySample = ISO8601DateFormatter().date(from: "2026-08-30T12:15:00Z")!
usageHistory.record(
  totals: ["site-a": 125], increment: ("site-a", 5), at: historySample,
  limits: ["site-a": 125], calendar: utc)
expect(
  usageHistory.hourly["2026-08-30"]?["12"]?["site-a"] == 5,
  "hourly website usage is recorded for the statistics chart")
expect(
  usageHistory.limitHitHourBySite["2026-08-30"]?["site-a"] == 12,
  "the first hour a website reaches its limit is recorded for statistics")
for day in 1...405 {
  let key = String(format: "2025-%03d", day)
  usageHistory.days[key] = ["site-a": 1]
  usageHistory.hourly[key] = ["00": ["site-a": 1]]
  usageHistory.limitHitHourBySite[key] = ["site-a": 0]
}
usageHistory.trim(keepingRecentDays: 400)
expect(
  usageHistory.days.count == 400 && usageHistory.hourly.count <= 400
    && usageHistory.limitHitHourBySite.count <= 400,
  "statistics retention remains capped at 400 days")
let policyCommand = DaemonCommand.updatePolicies([
  DaemonSitePolicy(id: "site-b", domains: ["example.net"], blocked: true)
])
let decodedCommand = try! JSONDecoder().decode(
  DaemonCommand.self, from: JSONEncoder().encode(policyCommand))
if case .updatePolicies(let policies) = decodedCommand {
  expect(
    policies.first?.id == "site-b" && policies.first?.blocked == true,
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

let query = dnsQuery(name: "www.example.com")
expect(DNSMessage.isStandardQuery(query), "ordinary single-question DNS queries are accepted")
var responseAsQuery = query
responseAsQuery[2] |= 0x80
expect(!DNSMessage.isStandardQuery(responseAsQuery), "DNS responses are rejected at query ingress")
var compressedQuery = query
compressedQuery.replaceSubrange(12..<16, with: [0xC0, 0x0C])
expect(
  !DNSMessage.isStandardQuery(compressedQuery),
  "compressed or self-referential query names are rejected at ingress")
expect(DNSMessage.questionName(in: query) == "www.example.com", "DNS question name parses")
let denied = DNSMessage.nxdomainResponse(for: query)!
expect(
  denied[0] == query[0] && denied[1] == query[1] && denied[2] & 0x80 == 0x80
    && denied[3] & 0x0F == 3, "NXDOMAIN response keeps the transaction and sets response flags")
expect(DNSMessage.isResponse(denied, to: query), "matching DNS responses are accepted")
var unrelated = denied
unrelated[1] ^= 0x01
expect(!DNSMessage.isResponse(unrelated, to: query), "unrelated DNS responses are rejected")
var answer = dnsQuery(name: "example.com")
answer[2] = 0x81
answer[3] = 0x80
answer[6] = 0
answer[7] = 1
answer.append(contentsOf: [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34])
expect(DNSMessage.addresses(in: answer) == ["93.184.216.34"], "DNS IPv4 answer parses")
expect(
  NetworkAddressPolicy.isSafeToBlock("93.184.216.34"),
  "public delivery addresses are eligible for site blocking")
expect(
  !NetworkAddressPolicy.isSafeToBlock("192.168.1.1")
    && !NetworkAddressPolicy.isSafeToBlock(
      "1.1.1.1", protectedAddresses: ["1.1.1.1"]),
  "private and explicitly protected infrastructure addresses are never blocked")

var ednsQuery = query
ednsQuery[11] = 1
ednsQuery.append(contentsOf: [0, 0, 41, 0x04, 0xd0, 0, 0, 0, 0, 0, 0])
expect(DNSMessage.udpPayloadSize(ednsQuery) == 1232, "EDNS UDP payload limits are honored")
expect(DNSMessage.udpPayloadSize(query) == 512, "ordinary DNS uses a 512-byte UDP limit")
expect(
  DNSMessage.nxdomainResponse(for: ednsQuery)?.count == query.count,
  "blocked replies discard EDNS bytes when clearing the additional record count")
expect(
  DNSMessage.serverFailureResponse(for: query)![3] & 0xf == 2,
  "upstream outages return SERVFAIL rather than a false site block")
var wrongType = denied
wrongType[wrongType.count - 3] = 28
expect(!DNSMessage.isResponse(wrongType, to: query), "responses must match the requested record type")
var invalidLabel = query
invalidLabel[13] = 0xff
expect(!DNSMessage.isStandardQuery(invalidLabel), "unreadable DNS names cannot enter the proxy")
let limitedAnswer = DNSMessage.limitingAnswerTTL(answer, to: 30)
expect(
  limitedAnswer[limitedAnswer.count - 7] == 30 && DNSMessage.addresses(in: limitedAnswer) == ["93.184.216.34"],
  "positive cache lifetimes are shortened while preserving address answers")

let challenge = UnlockChallenge.generate()
expect(challenge.split(separator: " ").count == 12, "unlock challenge contains 12 words")
expect(
  UnlockChallenge.matches(typed: challenge, challenge: challenge),
  "exact one-time unlock challenge matches")
expect(
  !UnlockChallenge.matches(typed: challenge + " extra", challenge: challenge),
  "different unlock challenge is rejected")

let processNettop = """
  Browser One.998,,
  tcp4 192.168.1.2:50123<->93.184.216.34:443,en0,Established,1500,230
  Browser Two.402,,
  tcp4 192.168.1.2:50124<->104.16.0.1:443,en0,Established,900,100
  """
let processSnapshot = NetworkActivityDetector.parseNettopSnapshot(
  processNettop,
  matchingBySite: ["site-a": ["93.184.216.34"], "site-b": ["104.16.0.1"]])
expect(
  processSnapshot.totalsBySite["site-a"] == 1730
    && processSnapshot.processNamesBySite["site-a"] == ["Browser One"],
  "nettop traffic and ownership are attributed per website")
expect(
  NetworkActivityDetector.matchesForeground(
    processSnapshot.processNamesBySite["site-a"], hints: ["browser one"]),
  "foreground browser traffic is eligible for counting")
expect(
  !NetworkActivityDetector.matchesForeground(
    processSnapshot.processNamesBySite["site-a"], hints: ["browser two"]),
  "background browser traffic is ignored")
expect(
  NetworkActivityDetector.selectSingleSite(
    trafficDeltas: ["site-a": 50_000, "site-b": 2_000], newlyActive: ["site-b"],
    current: "site-a", eligible: ["site-a", "site-b"],
    lastTrafficAtBySite: ["site-a": Date(), "site-b": Date()]) == "site-b",
  "a newly active website becomes the one usage bucket even beside background traffic")
expect(
  NetworkActivityDetector.selectSingleSite(
    trafficDeltas: [:], newlyActive: [], current: "site-b",
    eligible: ["site-a", "site-b"], lastTrafficAtBySite: [:]) == "site-b",
  "one current usage bucket is retained during the warm buffer")

expect(
  SiteDomains.fallbackName(for: "www.example.com") == "Example",
  "website names are derived generically from the entered domain")

if failures > 0 {
  FileHandle.standardError.write(Data("\n\(failures) self-test(s) failed.\n".utf8))
  exit(1)
}
print("\nAll Web Time self-tests passed.")
