<p align="center">
  <img src="docs/assets/web-time.svg" width="112" height="112" alt="Web Time icon">
</p>

# Web Time

[![Build status](https://github.com/Haeri/WebTime/actions/workflows/release.yml/badge.svg)](https://github.com/Haeri/WebTime/actions/workflows/release.yml)
[![Latest version](https://img.shields.io/github/v/release/Haeri/WebTime?display_name=tag&sort=semver)](https://github.com/Haeri/WebTime/releases/latest)

A native macOS menu-bar app that gives distracting websites daily limits. Web Time estimates usage from local network activity and blocks configured domains through macOS DNS, sharing allowances across browsers and apps that use the system resolver. No account or browser extension is required.

## Features

- Separate daily limits for each website
- Works across browsers and native apps
- Menu-bar progress and Screen Time-style usage statistics
- Automatically blocks exhausted websites, with an unlocked 15-minute snooze
- Typing challenge protects settings and quitting from impulsive changes
- No account, analytics, telemetry, or cloud storage

## Install

Web Time requires macOS 13 or later.

1. Download and open `Web-Time.dmg`.
2. Open **Web Time Setup** and click **Install**.
3. Unlock the controls, add websites, and choose a daily limit for each one.

Installation requires an administrator password because Web Time runs a local DNS service. Web Time does not currently have an Apple Developer ID and is not notarized. If macOS blocks **Web Time Setup**, click **Done**, then open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway**. Confirm **Open**, then run the setup again.

To remove Web Time, open **Web Time Setup** and click **Uninstall**. Upgrading from an older version also restores network DNS settings that still point to the old Web Time proxy.

## Network behavior

Web Time registers temporary DNS routes only for the domains you configure. Other websites use macOS DNS directly. Allowed domains are forwarded to the current network's IPv4 or IPv6 DNS servers, including matching split-DNS VPN resolvers. Switching Wi-Fi, connecting a hotspot, or restarting the daemon does not require reinstalling or changing DNS settings.

Web Time never blocks entire IP addresses: unrelated websites can share those addresses. Blocking applies to new DNS lookups; cached answers and existing connections can continue, and apps using their own encrypted DNS can bypass it. Usage attribution from network addresses is approximate on shared hosting. Precise, immediate blocking of individual pages or established connections requires browser or flow-level integration beyond this DNS implementation.

See [network architecture and validation](docs/network-behavior.md) for implementation details and the device test checklist.

## Build from source

Install Xcode Command Line Tools, then run:

```bash
make test
make build
make install
```

To uninstall a source build:

```bash
make uninstall
```

## Data and privacy

Settings and usage history stay in:

```text
~/Library/Application Support/Web Time
```

Web Time does not collect browsing history or send usage data anywhere. See [PRIVACY.md](PRIVACY.md) for details.


## License

[MIT](LICENSE)
