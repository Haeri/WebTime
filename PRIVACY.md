# Privacy

Web Time has no account, analytics, telemetry, advertising, or cloud data store.

The following data stays on the Mac:

- configured website names, domains, and allowances;
- daily and hourly usage history;
- cached favicons;
- legacy DNS backups retained when upgrading older installations.

Web Time handles DNS requests only for configured domains, forwarding allowed requests to the current network's configured IPv4 or IPv6 DNS servers. Matching split-DNS domains use their own configured resolver. Other domains resolve directly through macOS. Web Time does not select a public fallback provider or retain an installation-time resolver. The selected resolver can observe the requests it receives in the same way any configured DNS provider can. Favicons are requested over HTTPS from each configured website or an HTTPS icon/CDN location declared by that website; configured domains are not sent through a centralized third-party icon service.

The menu app samples local connection metadata from `nettop`. This information is processed in memory and is not logged or transmitted by Web Time. The privileged service does not record DNS queries.

Local configuration and usage files live in `~/Library/Application Support/Web Time`.
