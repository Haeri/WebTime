# Privacy

Web Time has no account, analytics, telemetry, advertising, or cloud data store.

The following data stays on the Mac:

- configured website names, domains, and allowances;
- daily and hourly usage history;
- cached favicons;
- the pre-install DNS configuration needed for uninstall recovery.

To provide network-level enforcement, Web Time forwards ordinary DNS requests to the machine's existing IPv4 resolver, captured in a root-only file during installation. If no usable resolver can be discovered, the installer falls back to Cloudflare's `1.1.1.1`. The resolver can observe DNS lookups in the same way any configured DNS provider can. Favicons are requested over HTTPS from each configured website or an HTTPS icon/CDN location declared by that website; configured domains are not sent through a centralized third-party icon service.

The menu app samples local connection metadata from `nettop`. This information is processed in memory and is not logged or transmitted by Web Time. The privileged service does not record DNS queries.

Local configuration and usage files live in `~/Library/Application Support/Web Time`.
