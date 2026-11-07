import Foundation

/// Ready-made jobs an MCP client offers its user (slash commands in Claude Code): a fleet health report that only
/// reads, and an update run that changes machines one approved step at a time.
enum AgentPrompts {
    private static let group: JSONValue = ["name": "group", "description": "Only the machines in this group; every machine when left out",
                                           "required": false]

    static let list: [JSONValue] = [
        ["name": "fleet_health", "description": "Report machines that are offline, overloaded, nearly full or overdue a reboot. Reads only.",
         "arguments": [group]],
        ["name": "fleet_update", "description": "Install package updates on machines, one approved step at a time, and say which need a reboot.",
         "arguments": [group]],
    ]

    static func get(_ name: String, arguments: JSONValue) -> JSONValue? {
        let scope = arguments["group"]?.string.map { "the machines in the group \"\($0)\"" } ?? "every machine"
        let text: String
        switch name {
        case "fleet_health":
            text = """
            Check the health of \(scope) in SwiftPulse, without changing anything.

            1. list_hosts (with the group if one is given), then get_metrics for them. Machines that report "connecting" or \
            "idle" have no reading yet: wait a few seconds and ask again once.
            2. Flag a machine when it is offline; CPU is over 80 %; memory is over 90 %; any disk is over 90 %; the 15-minute \
            load is above its core count; TCP retransmissions are over 2 %; or uptime is over 90 days.
            3. For each flagged machine, read get_activity to see whether an earlier agent already worked on it.
            4. Answer with a short table (machine, problem, reading) and, for each problem, the next step you would take and \
            the command it needs. Don't run anything.
            """
        case "fleet_update":
            text = """
            Install package updates on \(scope) in SwiftPulse. Use the task "Package updates \(Date().formatted(date: .abbreviated, time: .omitted))" \
            for every call that changes something.

            1. list_hosts (with the group if one is given) and get_activity for them; skip machines another agent is updating.
            2. Find each machine's package manager with run_command "command -v apt-get dnf yum zypper apk pacman".
            3. Refresh and list pending updates (e.g. "apt-get update && apt list --upgradable"), one run_command per package \
            manager across all its machines, with sudo: true.
            4. Show me the counts and anything notable (a kernel, a database, a web server), then install them the same way \
            ("DEBIAN_FRONTEND=noninteractive apt-get -y upgrade", "dnf -y upgrade", …). Keep wait high; follow long runs with get_job.
            5. Report each machine's exit code. Check which need a reboot ("test -f /var/run/reboot-required" on Debian and \
            Ubuntu, "needs-restarting -r" on Red Hat) and ask me before rebooting any of them.
            """
        default:
            return nil
        }
        return ["description": .string(list.first { $0["name"]?.string == name }?["description"]?.string ?? ""),
                "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]]]
    }
}
