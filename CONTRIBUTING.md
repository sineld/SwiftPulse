# Contributing to SwiftPulse

Thanks for helping! Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with:

- your SwiftPulse and macOS versions,
- the server side if it matters: OS and version, SSH server, Docker version,
- what you did, what you expected and what happened instead,
- logs from **Settings › Logs** if they help.

**Never paste real hostnames, IP addresses, usernames, passwords or private keys** into an issue. Replace them with made-up values such as `203.0.113.10` or `web-01`. To report a security problem, follow [SECURITY.md](SECURITY.md) instead.

## Development setup

Requirements: macOS 15 or later, Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # SwiftTerm needs it, once per Xcode
git clone https://github.com/sineld/SwiftPulse.git
cd SwiftPulse
xcodegen generate                              # SwiftPulse.xcodeproj is generated, not committed
```

Run the tests before every pull request:

```bash
xcodebuild test -project SwiftPulse.xcodeproj -scheme SwiftPulse -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData CODE_SIGN_IDENTITY="-" \
  -skipPackagePluginValidation -skipMacroValidation
```

`Scripts/build.sh` builds a Release app into `dist/SwiftPulse.app`. Ad-hoc signed builds keep secrets in a file instead of the keychain; see "Signing and secrets" in the README.

## Pull requests

1. Keep each pull request focused on one change.
2. Add or update tests in `Tests/` for logic changes, such as parsers, key formats, connection specs, sync and MCP tools.
3. Ask before adding a new dependency.
4. Tests and fixtures must not contain real data: no real hostnames, IPs, usernames, keys or command output from your own servers. Use documentation addresses (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) and invented names.
5. Every destructive action must ask first, through `DeleteRequest` (see the README's development notes).
6. Update `CHANGELOG.md` under **Unreleased**.
7. Use a short, imperative English commit message, for example `Add keep-alive interval setting`.

GitHub Actions builds the app and runs the tests on every push and pull request.

## Code of conduct

Be kind and assume good intent. Harassment or discrimination isn't tolerated.

## Support

If SwiftPulse is useful to you, you can support it through [GitHub Sponsors](https://github.com/sponsors/sineld).
