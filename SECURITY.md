# Security policy

SwiftPulse stores SSH credentials and can run commands on your servers, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue** for a security problem. Report it privately instead:

- through GitHub: **Security → Report a vulnerability** on this repository, or
- by email to [sinan@sinaneldem.tr](mailto:sinan@sinaneldem.tr).

Include the SwiftPulse version, your macOS version, the steps to reproduce and what an attacker could do. Never include real passwords, private keys or server addresses. Use made-up ones.

You'll get a reply as soon as possible. SwiftPulse is maintained by one person in their spare time, so please allow a reasonable amount of time for a fix before you disclose the problem publicly.

## Supported versions

Only the latest release receives security fixes.

## What's in scope

- How SwiftPulse stores secrets: the login keychain for signed builds, `secrets.json` for ad-hoc builds.
- The encrypted sync vault (`SwiftPulse.spvault`).
- Host key verification.
- The local MCP server: its Unix socket, the approval flow and the tools it exposes to agents.
- Anything that could leak a credential, run a command without approval, or connect to a host without checking its key.
