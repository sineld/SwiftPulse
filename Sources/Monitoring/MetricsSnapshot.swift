import Foundation

/// Raw counters read from one `MetricsCollector.script` run. Rates need two snapshots (see `MachineStatus`).
struct MetricsSnapshot: Sendable {
    struct CPUTimes: Sendable { var user = 0.0, nice = 0.0, system = 0.0, idle = 0.0, iowait = 0.0, irq = 0.0, softirq = 0.0, steal = 0.0
        var total: Double { user + nice + system + idle + iowait + irq + softirq + steal }
        var busy: Double { total - idle - iowait }
    }
    struct Disk: Identifiable, Sendable { var id: String { mount }; let filesystem: String, mount: String, total: Int64, used: Int64, free: Int64 }
    struct NetCounters: Sendable { let rx: Int64, tx: Int64 }
    struct DiskIO: Sendable {
        let readBytes: Int64, writeBytes: Int64
        /// Completed reads and writes, and the milliseconds spent on them (for IOPS and average wait).
        var reads: Int64 = 0, writes: Int64 = 0, readMs: Int64 = 0, writeMs: Int64 = 0
    }
    /// /proc/net/snmp's Tcp counters.
    struct TCP: Sendable { var established: Int64 = 0, outSegments: Int64 = 0, retransmitted: Int64 = 0, failedAttempts: Int64 = 0 }
    struct Process: Identifiable, Sendable { var id: Int { pid }; let pid: Int, user: String, cpu: Double, mem: Double, rssBytes: Int64, command: String }

    var takenAt = Date()
    var hostname = "", kernel = "", osName = ""
    var coreCount = 0
    var cpuTotal = CPUTimes()
    var cpuCores: [CPUTimes] = []
    var memTotal: Int64 = 0, memAvailable: Int64 = 0, memFree: Int64 = 0, memCached: Int64 = 0, swapTotal: Int64 = 0, swapFree: Int64 = 0
    var load: [Double] = [0, 0, 0]
    var uptime: TimeInterval = 0
    var net: [String: NetCounters] = [:]
    var disks: [Disk] = []
    var diskIO: [String: DiskIO] = [:]
    var tcp: TCP?
    var processes: [Process] = []
    var temperatureC: Double?
    /// macOS: CPU busy percentage (user, system) over the poll's own one-second sample; Linux derives it from ticks.
    var cpuPercent: (user: Double, system: Double)?
    var primaryInterface = ""
    var publicIP = ""
    /// Interfaces backed by a device in sysfs: real (or VM) network cards. Empty where sysfs doesn't say (containers).
    var nics: Set<String> = []

    /// Interfaces that carry the machine's own traffic: not loopback, containers, bridges, tunnels or VMs, whose
    /// bytes also cross a physical interface and would be counted twice. The primary one when nothing else is left.
    var physicalInterfaces: [String] {
        // sysfs knows which interfaces are cards (it catches tunnels any name list misses, like OpenVPN's as0t0).
        let names = net.keys.filter { (nics.isEmpty || nics.contains($0)) && !Self.isVirtual($0) }.sorted()
        return names.isEmpty && net[primaryInterface] != nil ? [primaryInterface] : names
    }

    /// Bytes received and sent since boot over the physical interfaces.
    var traffic: NetCounters {
        physicalInterfaces.compactMap { net[$0] }.reduce(NetCounters(rx: 0, tx: 0)) { NetCounters(rx: $0.rx + $1.rx, tx: $0.tx + $1.tx) }
    }

    /// Interface name prefixes that carry no traffic of the machine's own: loopback, container and VM networking,
    /// tunnels and VPNs, and macOS's built-in peer-to-peer and helper links.
    private static let virtualInterfacePrefixes: [String] = {
        let loopback = ["lo"]
        let containersAndVMs = ["docker", "veth", "br-", "bridge", "virbr", "vmnet", "vnet", "cni", "flannel", "cali", "kube",
                                "lxc", "lxd", "podman"]
        let tunnels = ["tun", "tap", "utun", "wg", "tailscale", "zt", "vxlan", "gif", "stf"]
        let appleLinks = ["awdl", "llw", "anpi"]
        return loopback + containersAndVMs + tunnels + appleLinks
    }()

    static func isVirtual(_ name: String) -> Bool {
        virtualInterfacePrefixes.contains { name.hasPrefix($0) }
    }
}

enum MetricsCollector {
    /// One round trip; sections are delimited by `##NAME` lines. Busybox/GNU compatible.
    /// One SSH exec per poll. It always exits 0: a section that has nothing to say (no thermal sensor on a VM) must
    /// not fail the whole run, which Citadel reports as `CommandFailed`. Linux reads /proc; macOS gets the same sections from sysctl, vm_stat, netstat, top and
    /// ps, written the way the Linux ones are (meminfo lines, a /proc/net/dev table, sysfs-like NIC paths) so one
    /// parser reads both. macOS has no cumulative CPU ticks, so it reports the percentage over a one-second sample.
    static let script = #"""
    if [ "$(uname -s)" = Darwin ]; then
        echo '##HOST'; hostname; uname -r; sysctl -n hw.ncpu; echo "macOS $(sw_vers -productVersion)"
        echo '##CPUPCT'; top -l 2 -n 0 -s 1 | grep 'CPU usage' | tail -1
        echo '##MEM'; P=$(sysctl -n hw.pagesize); echo "MemTotal: $(( $(sysctl -n hw.memsize) / 1024 )) kB"
        vm_stat | awk -v p="$P" '{ gsub(/\./, "", $NF) } /Pages free/ { f = $NF } /Pages inactive/ { i = $NF } /Pages speculative/ { s = $NF } /File-backed pages/ { c = $NF }
          END { printf "MemFree: %d kB\nMemAvailable: %d kB\nCached: %d kB\n", f * p / 1024, (f + i + s) * p / 1024, c * p / 1024 }'
        sysctl -n vm.swapusage | awk '{ gsub(/M/, "", $3); gsub(/M/, "", $9); printf "SwapTotal: %d kB\nSwapFree: %d kB\n", $3 * 1024, $9 * 1024 }'
        echo '##LOAD'; sysctl -n vm.loadavg | tr -d '{}'
        echo '##UPTIME'; echo $(( $(date +%s) - $(sysctl -n kern.boottime | sed 's/^{ sec = \([0-9]*\).*/\1/') ))
        echo '##NET'; echo; echo; netstat -ibn | awk '$3 ~ /^<Link/ && !seen[$1]++ { printf "%s: %s 0 0 0 0 0 0 0 %s 0 0 0 0 0 0 0\n", $1, $(NF-4), $(NF-1) }'
        echo '##NIC'; networksetup -listallhardwareports 2>/dev/null | awk '/^Device:/ { print "/sys/class/net/" $2 "/device" }'
        echo '##ROUTE'; I=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }'); echo "1.1.1.1 dev $I src $(ipconfig getifaddr "$I" 2>/dev/null)"
        echo '##DISK'; df -Pk 2>/dev/null
        echo '##PS'; ps -Aceo pid,user,pcpu,pmem,rss,comm -r 2>/dev/null | head -n 16
    else
        echo '##HOST'; hostname; uname -r; nproc; [ -r /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME"
        echo '##CPU'; grep '^cpu' /proc/stat
        echo '##MEM'; cat /proc/meminfo
        echo '##LOAD'; cat /proc/loadavg
        echo '##UPTIME'; cat /proc/uptime
        echo '##NET'; cat /proc/net/dev
        echo '##NIC'; ls -d /sys/class/net/*/device 2>/dev/null
        echo '##ROUTE'; ip -o -4 route get 1.1.1.1 2>/dev/null
        echo '##DISK'; df -Pk 2>/dev/null
        echo '##DISKIO'; cat /proc/diskstats
        echo '##TCP'; grep '^Tcp:' /proc/net/snmp 2>/dev/null
        echo '##TEMP'; cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null
        echo '##PS'; ps -eo pid,user,pcpu,pmem,rss,comm --sort=-pcpu 2>/dev/null | head -n 16
    fi
    exit 0
    """#

    /// The script without its process list: `ps` on every machine at every poll costs the most and is shown only on
    /// a machine's status page (and to agents), so the monitor asks for it only then.
    static let scriptWithoutProcesses = script.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains("'##PS'") }.joined(separator: "\n")

    static func script(processes: Bool) -> String { processes ? script : scriptWithoutProcesses }

    static func parse(_ output: String) -> MetricsSnapshot {
        var snap = MetricsSnapshot()
        var section = ""
        var lines: [String: [String]] = [:]
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("##") { section = String(line.dropFirst(2)); continue }
            lines[section, default: []].append(line)
        }
        let host = lines["HOST"] ?? []
        snap.hostname = host.first ?? ""
        snap.kernel = host.count > 1 ? host[1] : ""
        snap.coreCount = host.count > 2 ? Int(host[2]) ?? 0 : 0
        snap.osName = host.count > 3 ? host[3] : ""

        for line in lines["CPU"] ?? [] {
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 8, let t = cpuTimes(f) else { continue }
            if f[0] == "cpu" { snap.cpuTotal = t } else { snap.cpuCores.append(t) }
        }
        if snap.coreCount == 0 { snap.coreCount = snap.cpuCores.count }
        // "CPU usage: 3.5% user, 3.26% sys, 93.67% idle"
        if let line = lines["CPUPCT"]?.first(where: { $0.contains("CPU usage") }) {
            let values = line.split(separator: " ").filter { $0.hasSuffix("%") }.compactMap { Double($0.dropLast()) }
            if values.count >= 2 { snap.cpuPercent = (values[0], values[1]) }
        }

        for line in lines["MEM"] ?? [] {
            let f = line.split(whereSeparator: { $0 == ":" || $0 == " " })
            guard f.count >= 2, let kb = Int64(f[1]) else { continue }
            let bytes = kb * 1024
            switch f[0] {
            case "MemTotal": snap.memTotal = bytes
            case "MemFree": snap.memFree = bytes
            case "MemAvailable": snap.memAvailable = bytes
            case "Cached": snap.memCached += bytes
            case "Buffers": snap.memCached += bytes
            case "SwapTotal": snap.swapTotal = bytes
            case "SwapFree": snap.swapFree = bytes
            default: break
            }
        }
        if let l = lines["LOAD"]?.first { snap.load = l.split(separator: " ").prefix(3).compactMap { Double($0) } }
        if let u = lines["UPTIME"]?.first?.split(separator: " ").first { snap.uptime = Double(u) ?? 0 }

        for line in (lines["NET"] ?? []).dropFirst(2) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let f = parts[1].split(separator: " ").compactMap { Int64($0) }
            guard f.count >= 9, name != "lo" else { continue }
            snap.net[name] = .init(rx: f[0], tx: f[8])
        }
        snap.nics = Set((lines["NIC"] ?? []).compactMap { $0.split(separator: "/").dropLast().last.map(String.init) })
        if let route = lines["ROUTE"]?.first {
            let f = route.split(separator: " ").map(String.init)
            if let i = f.firstIndex(of: "dev"), i + 1 < f.count { snap.primaryInterface = f[i + 1] }
            if let i = f.firstIndex(of: "src"), i + 1 < f.count { snap.publicIP = f[i + 1] }
        }
        if snap.primaryInterface.isEmpty { snap.primaryInterface = snap.net.max { $0.value.rx < $1.value.rx }?.key ?? "" }

        // POSIX `df -Pk` (1024-byte blocks), which BusyBox and every coreutils have; system mounts are dropped here.
        var seen = Set<String>()
        for line in (lines["DISK"] ?? []).dropFirst() {
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 6, let total = Int64(f[1]), let used = Int64(f[2]), let free = Int64(f[3]), total > 0 else { continue }
            let mount = f[5...].joined(separator: " ")
            guard !isSystemMount(filesystem: f[0], mount: mount), seen.insert(f[0]).inserted else { continue } // bind mounts once
            snap.disks.append(.init(filesystem: f[0], mount: mount, total: total * 1024, used: used * 1024, free: free * 1024))
        }
        // macOS: "/" is the sealed system snapshot; what fills up is the Data volume in the same APFS container.
        if let data = snap.disks.firstIndex(where: { $0.mount == "/System/Volumes/Data" }) {
            let disk = snap.disks[data]
            snap.disks.removeAll { $0.mount == "/" || $0.mount == "/System/Volumes/Data" }
            snap.disks.insert(.init(filesystem: disk.filesystem, mount: "/", total: disk.total, used: disk.used, free: disk.free), at: 0)
        }
        var io: [String: MetricsSnapshot.DiskIO] = [:]
        for line in lines["DISKIO"] ?? [] {
            let f = line.split(separator: " ").map(String.init)
            // major minor name reads merged sectorsRead msReading writes merged sectorsWritten msWriting …
            guard f.count >= 14, let rd = Int64(f[5]), let wr = Int64(f[9]) else { continue }
            io[f[2]] = .init(readBytes: rd * 512, writeBytes: wr * 512, reads: Int64(f[3]) ?? 0, writes: Int64(f[7]) ?? 0,
                             readMs: Int64(f[6]) ?? 0, writeMs: Int64(f[10]) ?? 0)
        }
        snap.diskIO = io.filter { isWholeDisk($0.key, among: io.keys) }
        if let t = lines["TEMP"]?.first, let milli = Double(t) { snap.temperatureC = milli / 1000 }
        // Two lines: the field names, then the values.
        if let tcp = lines["TCP"], tcp.count >= 2 {
            let names = tcp[0].split(separator: " ").dropFirst().map(String.init)
            let values = tcp[1].split(separator: " ").dropFirst().compactMap { Int64($0) }
            let field = Dictionary(zip(names, values), uniquingKeysWith: { a, _ in a })
            snap.tcp = MetricsSnapshot.TCP(established: field["CurrEstab"] ?? 0, outSegments: field["OutSegs"] ?? 0,
                           retransmitted: field["RetransSegs"] ?? 0, failedAttempts: field["AttemptFails"] ?? 0)
        }
        for line in (lines["PS"] ?? []).dropFirst() {
            let f = line.split(separator: " ", maxSplits: 5).map(String.init)
            guard f.count >= 6, let pid = Int(f[0]), let cpu = Double(f[2]), let mem = Double(f[3]), let rss = Int64(f[4]) else { continue }
            snap.processes.append(.init(pid: pid, user: f[1], cpu: cpu, mem: mem, rssBytes: rss * 1024, command: f[5]))
        }
        return snap
    }

    /// Whether a `/proc/diskstats` device is a disk to count. Devices stacked on other disks (LVM `dm-`, RAID `md`),
    /// loop, RAM, floppy and optical devices are not; neither is a partition, whose name is its disk's name plus a
    /// number (`sda1`), with a `p` in between when the disk's name ends in a digit (`nvme0n1p1`, `mmcblk0p2`).
    static func isWholeDisk(_ name: String, among names: some Collection<String>) -> Bool {
        let notDisks = ["loop", "ram", "zram", "fd", "sr", "dm-", "md"]
        if notDisks.contains(where: { name.hasPrefix($0) }) { return false }
        let stem = String(name.reversed().drop(while: \.isNumber).reversed())
        guard stem.count < name.count else { return true } // no trailing number, so not a partition
        let possibleDisks = stem.hasSuffix("p") ? [stem, String(stem.dropLast())] : [stem]
        return !possibleDisks.contains { !$0.isEmpty && $0 != name && names.contains($0) }
    }

    /// Pseudo, container and snapshot mounts, which say nothing about the machine's disk space.
    static func isSystemMount(filesystem: String, mount: String) -> Bool {
        let pseudo: Set = ["tmpfs", "devtmpfs", "udev", "overlay", "squashfs", "efivarfs", "none", "shm", "proc", "sysfs", "cgroup",
                           "cgroup2", "log2ram", "folder2ram", "devfs"]
        let systemPaths = ["/run", "/sys", "/proc", "/dev", "/snap/", "/var/snap/", "/var/lib/docker/", "/var/lib/containers/",
                           "/var/lib/kubelet/", "/run/containerd/",
                           // macOS: APFS system volumes (Data is kept), simulator runtimes, cryptexes, Recovery
                           "/Library/Developer/CoreSimulator/", "/private/var/", "/Volumes/Recovery"]
        if mount.hasPrefix("/System/Volumes/") && mount != "/System/Volumes/Data" { return true }
        return pseudo.contains(filesystem) || filesystem.hasPrefix("/dev/loop") || filesystem.hasPrefix("/dev/zram")
            || systemPaths.contains { mount == $0 || mount.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    private static func cpuTimes(_ f: [String]) -> MetricsSnapshot.CPUTimes? {
        let v = f.dropFirst().compactMap { Double($0) }
        guard v.count >= 7 else { return nil }
        return .init(user: v[0], nice: v[1], system: v[2], idle: v[3], iowait: v[4], irq: v[5], softirq: v[6], steal: v.count > 7 ? v[7] : 0)
    }
}
