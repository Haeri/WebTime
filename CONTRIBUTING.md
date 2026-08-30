# Contributing

Web Time is a small native macOS utility. Changes should keep the project local-first, dependency-light, and understandable without a separate build system.

## Development

```bash
make test
make build
```

Before opening a change, also run:

```bash
bash -n Scripts/*.sh
plutil -lint Resources/*.plist
```

Keep UI changes consistent with standard AppKit behavior, include a self-test for core behavior, and do not commit `.build`, user configuration, usage history, cached favicons, DNS backups, logs, or machine-specific paths.

## Publishing

The website lives in `docs/` and is deployed by `.github/workflows/pages.yml`. In the GitHub repository, set **Settings → Pages → Build and deployment → Source** to **GitHub Actions** once.

Releases are tag-driven. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, commit the change, then push a matching tag such as `v0.6.0`. The release workflow refuses a tag whose version does not match the app, and publishes `Web-Time.dmg` only after tests and a clean release build succeed.
