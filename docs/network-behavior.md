# Domain-scoped DNS

## Problem and change

The previous installer set every network service's DNS to `127.0.0.1`. The daemon then forwarded all DNS requests to one IPv4 resolver captured during installation. Moving from Wi-Fi to a hotspot left it forwarding to the previous router, so unrelated sites lost DNS too. PF rules based on learned destination IPs could also affect unrelated services sharing those IPs.

The daemon now binds UDP and TCP to `127.0.0.1:5354` before accepting policies. It registers `SupplementalMatchDomains` for only the configured domains in a session-owned SystemConfiguration key, `State:/Network/Service/local.web-time/DNS`. There is no default/catch-all route and no persistent network-service DNS override. Quitting clears the domain routes; configd removes session-owned keys when the daemon disconnects. A new daemon instance ID makes the menu app resend policies after a restart, even if it never sampled the outage.

The implementation uses Apple's [supplemental-domain DNS configuration](https://github.com/apple-oss-distributions/configd/blob/main/Plugins/IPMonitor/dns-configuration.c) and [per-session dynamic store option](https://developer.apple.com/documentation/systemconfiguration/kscdynamicstoreusesessionkeys).

## Forwarding and failure behavior

Each request reads an atomic snapshot of the current default and service DNS configuration, excluding Web Time's own route. Longest matching supplemental domains take precedence, preserving split-DNS isolation. Up to three configured upstream endpoints are tried with bounded timeouts. There is no hardcoded public fallback. IPv4, IPv6, link-local IPv6 interface scopes, custom resolver ports, EDNS payload limits, and TCP fallback for truncated UDP replies are supported.

Exhausted domains receive NXDOMAIN, while unavailable resolvers receive SERVFAIL. The policy is checked again after upstream I/O, so an in-flight response cannot defeat a newly exhausted allowance. Address observations are bounded, stay in memory, and clear when network configuration or site domains change. Responses from an earlier network cannot repopulate the observations. Unrelated DNS does not depend on this daemon in the first place.

No PF rules are created or IP-wide connections terminated. Positive unsigned DNS answer TTLs are capped at 30 seconds for configured sites. When the set of blocked domains changes, the daemon flushes the macOS DNS cache so a new block or snooze applies to the next lookup instead of waiting for a cached answer to expire. Existing DNS caches, signed answers, persistent TCP/QUIC streams, application DNS, and shared hosting limit the precision of DNS-based tracking and enforcement. This implementation cannot promise immediate termination, exact per-page attribution, or blocking of DNS-over-HTTPS. Those guarantees require a separate browser/flow-aware design.

## Upgrade and removal

The shared `Scripts/legacy-dns.sh` migration restores only legacy service settings that still equal `127.0.0.1`. DHCP-backed services return to automatic DNS; manual DNS lists are restored verbatim. User/VPN changes are preserved, deleted adapters are skipped, and invalid backups or failed restorations stop migration before the old daemon is removed. A migration marker prevents a later uninstall from restoring obsolete settings. Install and uninstall clear only the legacy Web Time PF anchor, after stopping the old daemon.

Fresh installations do not capture or change network-service DNS. The setup payload includes the migration helper for both upgrade and removal.

## Automated verification

`make test` runs the existing core self-tests, standalone daemon regression tests (compatible with Command Line Tools without XCTest), and shell migration tests. The daemon tests compile the production components and use fake network snapshots plus real loopback DNS servers on temporary ports. They do not change system DNS or access the Internet.

Coverage includes default-network replacement, excluding Web Time's own resolver, split-DNS routing, link-local IPv6 scope selection, stale response rejection, policy changes during lookup, shared-IP isolation, failed route registration, restart IDs, UDP forwarding, upstream failure fallback, TCP forwarding and truncation fallback, DNS packet correctness, DHCP/manual backup restoration, and repeat upgrade/removal behavior.

`Scripts/verify-live-dns.sh` (run with Web Time uninstalled) starts the built daemon with `sudo` and checks against the real macOS resolver that a configured domain is routed, blocked, and snoozed while unrelated DNS keeps working, and that the route disappears when the daemon exits.

## Device acceptance checklist

Run on a test Mac before release; automated tests do not physically switch Wi-Fi or install the privileged service.

1. Record `networksetup -getdnsservers "Wi-Fi"`, then install the new build over the old one. Confirm the old loopback override is restored to automatic/manual DNS as appropriate.
2. Configure two domains and exhaust one allowance. Confirm `scutil --dns` shows supplemental routes for those domains on port 5354 and normal default DNS for everything else. Check resolution using a system-resolver client (`dscacheutil -q host -a name DOMAIN`); `dig` alone does not exercise macOS supplemental routing.
3. Keep one unrelated site open and load additional unrelated sites while switching Wi-Fi → hotspot → Wi-Fi, including a captive portal. Confirm unrelated resolution works and only the configured exhausted domain receives a block on a new lookup.
4. Repeat with an IPv6 network and a split-DNS VPN. Check a configured private domain uses its matching resolver and is not forwarded to a public resolver if the VPN resolver fails.
5. Stop or kill the daemon on the test Mac. Confirm its supplemental route disappears, ordinary DNS stays available, and a launchd restart causes the app to resend policies. Repeat after sleep/wake.
6. Test snooze, daily rollover, domain removal, and quitting. Allow for browser DNS caches and existing streams. Confirm no Web Time PF rules exist.
7. Change a network service's DNS manually after upgrading, then uninstall. Confirm that setting is preserved and Web Time's supplemental routes disappear.
