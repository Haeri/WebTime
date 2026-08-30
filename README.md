<p align="center">
  <img src="docs/assets/web-time-1024.png" width="128" height="128" alt="Web Time icon">
</p>

# Web Time for macOS

A local, native menu-bar utility that gives independently configurable daily allowances to distracting websites and blocks each one at the network layer when its allowance is gone.

This repository is intentionally small: no account, browser extension, analytics, cloud backend, or third-party runtime.

[Download the latest macOS release](../../releases/latest/download/Web-Time.dmg)

## What it does

- Tracks multiple websites across Safari, Chrome, Firefox, Brave, Edge, native wrappers, and other local clients using network connections rather than browser history.
- Gives every configured website its own domain set, daily allowance, usage counter, and block state.
- Counts active transfer time only when its owning browser is the foreground app, with a short warm buffer for bursty video and feed loading.
- Shows a favicon, activity state, exact remaining time, configured allowance, and a color-coded bar that drains for the five most-used websites, ordered by today's usage. The compact menu-bar icon is just the active favicon and one quota-color dot; hover it for exact time. Manage Websites and Statistics always retain the full list.
- Selects one most-recently active website as the usage bucket, so background traffic cannot consume two allowances simultaneously.
- Blocks each exhausted site's DNS names and learned delivery addresses independently. Existing TCP and QUIC states are killed at cutoff.
- Locks administrative controls by default. A fresh 12-word manual typing challenge unlocks site editing and Quit; five minutes without app interaction relocks them.
- Includes a native Screen Time–style statistics window with seven-day totals, hourly activity, per-site usage, limits, favicons, search, and date navigation. Up to 400 days are retained.
- Runs both the UI and privileged network service under `launchd`, including after restart.
- Has no account, analytics, telemetry, or cloud storage. See [PRIVACY.md](PRIVACY.md) for the local and network data flows.

```text
Browsers and apps
       │ DNS + connections
       ▼
local DNS proxy (root daemon) ── attributes actual site/CDN addresses per rule
       │                                      │
       │ allowed DNS                           └── status to menu-bar timer
       ▼
existing upstream DNS               per-site limit: NXDOMAIN + PF address block
```

## Requirements

- macOS 13 or newer
- Apple Silicon or Intel Mac
- Full Xcode, or Apple Command Line Tools (`xcode-select --install`)

The included Swift wrapper also handles the temporary compiler/default-SDK patch mismatch present in the Command Line Tools on the machine where this was created.

## Build and install

From Terminal:

```bash
cd /path/to/WebTime
make test
make install
```

For a published build, download `Web-Time.dmg`, open it, and double-click **Install Web Time**. Releases are ad-hoc signed rather than Apple-notarized, so macOS may require you to Control-click the installer and choose **Open** once. The installer asks for an administrator password because the local DNS proxy and launch service operate at the system level.

`make install` first builds an ad-hoc-signed local app, then asks for the Mac administrator password. It installs:

- `/Applications/Web Time.app`
- `/Library/PrivilegedHelperTools/webtimed`
- one system LaunchDaemon and one per-user LaunchAgent
- a backup of the current DNS settings under `/Library/Application Support/Web Time`

The installer points active macOS network services at the local DNS proxy. Before doing that, it captures the machine's current IPv4 resolver and stores it in a root-only local file for ordinary DNS forwarding. If no usable resolver can be discovered, it falls back to Cloudflare's `1.1.1.1`. The resolver file path is configured in `Resources/local.web-time.daemon.plist`.

After installation, a small gauge appears in the menu bar:

1. Choose **Unlock controls…** and manually type the generated 12-word phrase.
2. Choose **Manage websites…** to add, edit, or remove entries and set each daily allowance.
3. Paste a normal website address. Web Time names known services, fills their media/CDN domains, and learns changing A/AAAA addresses from live DNS automatically. An optional field remains for unusual third-party domains.
4. Leave the app alone and controls relock after five minutes. **Quit Web Time** remains visible but disabled while locked; while unlocked, it stops enforcement until the next login or manual launch.

Choose **Statistics…** at any time to inspect daily and weekly usage.

The app's data is stored in `~/Library/Application Support/Web Time`. Force-quitting while controls are locked causes `launchd` to restart it; the guarded Quit command first clears limiter-owned blocks and unloads the current login's agent.

## Uninstall and restore networking

Run:

```bash
cd /path/to/WebTime
make uninstall
```

The uninstall script unloads both services, clears the private PF anchor, restores every DNS setting captured during installation, flushes the DNS cache, and removes the installed app/helper. It does not remove the per-user usage/configuration files, so reinstalling does not silently reset today's timer. Those can be deleted separately if desired.

## How tracking works

The root daemon receives system DNS requests locally. When an allowed request matches a configured domain, it records the returned A/AAAA addresses under that site's ID—IP addresses are never entered or hardcoded. The menu app takes one `nettop` sample, attributes connection-byte changes to each site and owning process, and counts only when that process matches the foreground app. If `nettop` is unavailable because of local privacy restrictions, it conservatively falls back to matching open sockets.

This is closer to actual consumption than counting time merely because a tab exists. Media loads in bursts, so each foreground burst keeps that site “warm” for the configured grace period. Switching to another app now stops eligibility immediately. Two tabs in the same foreground browser cannot be distinguished perfectly, and reading a completely static page after all network activity stops can be undercounted. Reliably knowing the foreground URL in every browser would require intrusive Accessibility/Automation permissions or separate browser extensions; this version deliberately stays permission-free.

At a site's cutoff, the daemon returns NXDOMAIN for only that site's domains, combines the addresses of all currently exhausted sites in the private `local.web-time` PF anchor, and kills matching states. Other PF configuration is not replaced or disabled.

## Honest limits and threat model

This is a friction tool, not parental-control or endpoint-security software. It is designed to stop an impulsive switch between normal browsers. It does not claim to resist the Mac administrator, who can always unload a daemon, edit local data, boot another OS, or remove the software.

Specific limitations:

- A manually configured VPN, remote desktop, web proxy, Tor, or encrypted DNS service that ignores macOS DNS can conceal the final site address. Preventing all of those robustly requires an Apple Network Extension content filter and Apple-granted entitlements/signing.
- Sites continually change their delivery domains. Custom entries may occasionally need another CDN domain added in settings.
- Large platforms sometimes share delivery addresses across services. PF rules are limited to addresses learned from configured lookups, but a shared address can briefly affect an unrelated request after cutoff.
- The usage ledger is a local user file. The typing challenge discourages an easy menu click, but the timer is not tamper-proof against deliberate file editing.
- The DNS proxy currently supports normal UDP DNS. macOS uses EDNS and almost all replies fit; an unusually large response requiring TCP retry can fail while the limiter is installed.

For a personal tool, this tradeoff avoids browser surveillance, HTTPS interception, kernel extensions, and a paid Apple Developer distribution setup.

## Troubleshooting

Check whether both jobs are loaded:

```bash
launchctl print system/local.web-time.daemon
launchctl print gui/$(id -u)/local.web-time.agent
```

Inspect the daemon log and DNS configuration:

```bash
tail -100 /var/log/web-time.log
scutil --dns | grep nameserver
dig @127.0.0.1 youtube.com
```

If websites are not being tracked, first inspect the daemon log. Port 53 may already be owned by local DNS software such as dnsmasq, AdGuard, or a corporate security client. Remove the conflict or uninstall this limiter to restore the previous DNS settings.

## Development

```bash
./Scripts/swift.sh run WebTimeSelfTest
./Scripts/build-app.sh
```

Core behavior is covered by a dependency-free self-test executable for independent counters and limits, persistence, daily rollover, domain normalization/boundaries, known CDN expansion, DNS parsing/NXDOMAIN generation, one-time challenges, and per-site `nettop` attribution. The scripts are checked with `bash -n` and all plists with `plutil -lint`.

Pushing a version tag matching `Resources/Info.plist`—for example `v0.6.0`—runs the macOS release workflow, verifies the version, runs the self-tests, builds the app and daemon, creates `Web-Time.dmg` plus its checksum, and publishes a GitHub release. Pushes to `main` that change `docs/` deploy the one-page site through GitHub Pages.

## License

Web Time is available under the [MIT License](LICENSE).

See [CONTRIBUTING.md](CONTRIBUTING.md) before publishing changes and [SECURITY.md](SECURITY.md) for private vulnerability reporting.
