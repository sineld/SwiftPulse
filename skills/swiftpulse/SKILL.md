---
name: swiftpulse
description: Work on the user's SSH machines through SwiftPulse's MCP server — list machines and their live load, run commands on one or many machines (the user approves, SwiftPulse signs in with its own saved credentials), read Docker containers and logs, add or change machines, identities, snippets and port forwards, and keep each machine's agent activity log. Use whenever a task touches the user's servers, fleets, deploys, updates, containers or "my machines".
---

# SwiftPulse

SwiftPulse is the user's SSH client and server monitor for macOS. Its MCP server (`swiftpulse`) knows every
machine the user saved: address, port, user, group, tags, how it signs in, the jump hosts it goes through, its
live CPU, memory, disk, load, network and temperature, and its Docker containers.

## Set up (once)

SwiftPulse must be running with **Settings › MCP Server** turned on.

- Claude Code: `claude mcp add swiftpulse -- /Applications/SwiftPulse.app/Contents/Resources/swiftpulse-mcp`
- Codex (`~/.codex/config.toml`):
  ```toml
  [mcp_servers.swiftpulse]
  command = "/Applications/SwiftPulse.app/Contents/Resources/swiftpulse-mcp"
  ```
- Any other MCP client: a stdio server with that command. Settings › MCP Server shows the exact path of the
  installed app.

## Rules

1. **Read the machine's history first.** Before working on a machine, call `get_activity` with its name:
   earlier agents may have changed it.
2. **Name the task.** Give every call that changes something a `task`: a short name for the goal ("Install
   nginx", "Rotate TLS certificate"). Use the same task for every step toward that goal; the steps are kept as one
   entry in the machine's history.
3. **Log what you do outside SwiftPulse.** If you change a machine with your own `ssh`, `scp`, `rsync` or a
   deploy tool, call `log_activity` afterwards with the machines, a one-line summary, the commands and the same
   task.
4. **Never ask for secrets.** You don't need passwords or keys: `run_command` signs in with SwiftPulse's saved
   credentials. To give a machine a new key, use `add_identity` with `generate: true` and hand the user the public
   key it returns (or append it to `~/.ssh/authorized_keys` with `run_command`). Never put a secret in a command,
   a snippet or `log_activity`.
5. **The user approves every change.** `run_*`, `add_*`, `update_*`, `remove_*` and port forward starts and stops
   wait for the user. Ask for one clear step at a time, so the approval says exactly what will happen; batch the
   same command across machines with `targets` instead of calling once per machine.
6. **Host keys.** A machine whose key SwiftPulse hasn't verified fails with `host_key_unverified`. Don't try to
   work around it: ask the user to connect once from SwiftPulse's terminal and check the fingerprint.
7. **Long runs become jobs.** When the machines take longer than `wait` seconds, `run_command` returns a job id
   with the results so far; the command keeps running. Poll `get_job` every few seconds instead of starting it
   again. Pass a larger `wait` for runs you expect to take minutes, or a smaller one to get control back early.
8. **Prefer reads.** `get_metrics`, `list_containers` and `container_logs` answer without asking the user; use
   them to find out what's wrong before proposing a command.

## Tools

| Tool | What it does |
|---|---|
| `list_hosts`, `get_host` | Machines (filter by `query`, `group`, `tag`), one machine with live metrics |
| `get_metrics` | CPU, memory, swap, disks, load, network, disk I/O, temperature, top processes |
| `export_ssh_config` | `Host` blocks for your own `ssh` (no keys; works when the keys are in `ssh-agent`) |
| `run_command`, `run_snippet` | Run on `targets`: `{hosts: [...]}`, `{group}`, `{tag}` or `{all: true}`; `sudo` runs `sudo -n` |
| `get_job`, `cancel_job` | Follow or stop a run that outlasted its `wait` (120 s by default) |
| `list_containers`, `container_logs` | Docker on a machine |
| `add_host`, `update_host`, `remove_host` | Machines; `password` is write-only; `auth: "none"` for Tailscale SSH, `proxy_command` for `cloudflared access ssh --hostname %h` and the like |
| `list_identities`, `add_identity`, `remove_identity` | Identities and their SSH keys; only public keys come back |
| `list_snippets`, `add_snippet`, `update_snippet`, `remove_snippet` | Saved scripts |
| `list_port_forwards`, `add_port_forward`, `start_/stop_/remove_port_forward` | Local, remote and dynamic (SOCKS5) forwards |
| `get_activity`, `log_activity` | The agent history of each machine |

## Example: update every production machine

1. `list_hosts` with `group: "Production"`; `get_activity` for them.
2. `run_command` with `targets: {group: "Production"}`, `command: "apt-get update && apt-get -y upgrade"`,
   `sudo: true`, `task: "Monthly updates"`.
3. For the machines whose exit code isn't 0, read the output and fix them one by one, same task.
4. `run_command` with `command: "test -f /var/run/reboot-required && echo reboot"` to see which need a reboot,
   and ask the user before rebooting.

## Example: find out why a container keeps restarting

1. `list_containers` with the machine: look at `state`, `status` and memory.
2. `container_logs` with the container and `lines: 500`.
3. `get_metrics` for the machine: memory and disk pressure.
4. Propose the fix; apply it with `run_command` (`task: "Fix <container> restarts"`) once the user agrees.
