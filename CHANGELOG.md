# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1] - 2026-11-07

First public release.

### Added
- Dashboard with live metrics for Linux and macOS hosts, a status page per machine, an all-processes view with terminate and force kill, a world map, and a menu bar monitor.
- SSH terminal (SwiftTerm) with automatic reconnect, a snippets and status inspector, and optional shell integration that follows the current folder.
- SFTP browser with a local "This Mac" pane, drag and drop, queued transfers with speed, time left, cancel and retry, folder uploads and downloads, and a remote text editor.
- Local, remote and dynamic (SOCKS5) port forwarding with auto start.
- Docker panel: overview, containers, Compose, images, volumes, networks, events, prune, logs, inspect and a shell inside a container.
- Machines, groups and tags; identities; SSH key generation and import; SOCKS5 and HTTP CONNECT proxies; jump hosts and ProxyCommand; import from `~/.ssh/config`.
- Snippets that run on several machines at once, with results per machine.
- Host key verification, with a warning when a key changes.
- MCP server for AI agents over a private Unix socket, with an approval panel, jobs, an activity log, and a Claude Code skill.
- Encrypted sync through a folder you choose (PBKDF2-HMAC-SHA256 and AES-GCM), with merge, replace and synced deletions.
- Universal (Apple silicon + Intel) release signed with a Developer ID and notarized by Apple, distributed as a DMG. `Scripts/release.sh` builds it.
- GitHub Actions workflow that builds the app and runs the tests.
- <kbd>⌘</kbd><kbd>F</kbd> focuses the search field on every page and sheet that has one.
- A Docker card on each machine's status page with the engine, containers, images and their CPU and memory use; clicking it opens the machine's Docker page.

### Fixed
- Moving secrets from `secrets.json` to the keychain no longer deletes the file when a keychain write fails, so no secret is lost.
- An old `secrets.json` left in the former sandbox container is no longer copied back on every launch, which could overwrite newer secrets in the keychain.
- When an agent disconnects, its request waiting for approval is closed and denied, so nothing can be approved for a client that is gone.
- The Docker panel no longer hangs on machines where the SSH user isn't in the `docker` group: `sg docker` asked for the group password and waited forever, so passwordless `sudo -n docker` was never tried. `sg docker` now runs only for members of the group, and Docker commands get no input, so a password prompt fails instead of waiting.
- Tests never touch the user's data: no real keychain, `secrets.json`, database, sync vault or MCP socket, and no leftover files in `~/Library/Preferences`.
