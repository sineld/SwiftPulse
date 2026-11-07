import Foundation

/// Human-facing metrics derived from two consecutive snapshots.
struct MachineStatus: Sendable {
    struct CPU: Sendable { var total = 0.0, user = 0.0, system = 0.0, nice = 0.0, iowait = 0.0, steal = 0.0; var cores: [Double] = [] }
    struct Rate: Sendable { var rx = 0.0, tx = 0.0 } // bytes/s

    var snapshot: MetricsSnapshot
    var cpu = CPU()
    var network = Rate()
    var diskIO = Rate() // rx = read, tx = write
    /// One disk's activity over the last poll.
    struct Device: Identifiable, Sendable {
        var id: String { name }
        let name: String
        var read = 0.0, write = 0.0      // bytes/s
        var iops = 0.0                   // reads and writes per second
        var awaitMs = 0.0                // average time per request
    }
    var devices: [Device] = []
    /// Share of TCP segments sent that were retransmissions, over the last poll (percent); nil without counters.
    var tcpRetransmitPercent: Double?
    var loadHistory: [(Date, [Double])] = []

    var memUsed: Int64 { max(snapshot.memTotal - snapshot.memAvailable, 0) }
    var memPercent: Double { snapshot.memTotal > 0 ? Double(memUsed) / Double(snapshot.memTotal) * 100 : 0 }
    var swapUsed: Int64 { max(snapshot.swapTotal - snapshot.swapFree, 0) }
    var rootDisk: MetricsSnapshot.Disk? { snapshot.disks.first { $0.mount == "/" } ?? snapshot.disks.max { $0.total < $1.total } }
    var diskPercent: Double { rootDisk.map { Double($0.used) / Double($0.total) * 100 } ?? 0 }
    var totalDiskBytes: Int64 { snapshot.disks.reduce(0) { $0 + $1.total } }

    init(current: MetricsSnapshot, previous: MachineStatus?) {
        snapshot = current
        loadHistory = (previous?.loadHistory ?? []) + [(current.takenAt, current.load)]
        if loadHistory.count > 120 { loadHistory.removeFirst(loadHistory.count - 120) }
        if let percent = current.cpuPercent {
            cpu = CPU(total: percent.user + percent.system, user: percent.user, system: percent.system)
        }
        guard let prev = previous?.snapshot else { return }
        if current.cpuPercent == nil { cpu = Self.cpu(prev: prev, cur: current) }
        let dt = max(current.takenAt.timeIntervalSince(prev.takenAt), 0.5)
        var rx: Int64 = 0, tx: Int64 = 0
        for name in current.physicalInterfaces {
            guard let a = prev.net[name], let b = current.net[name] else { continue }
            rx += max(b.rx - a.rx, 0); tx += max(b.tx - a.tx, 0) // a counter that went back was reset: no traffic, not negative
        }
        network = Rate(rx: Double(rx) / dt, tx: Double(tx) / dt)
        var rd: Int64 = 0, wr: Int64 = 0
        for (name, io) in current.diskIO { if let p = prev.diskIO[name] { rd += max(io.readBytes - p.readBytes, 0); wr += max(io.writeBytes - p.writeBytes, 0) } }
        diskIO = Rate(rx: Double(rd) / dt, tx: Double(wr) / dt)
        devices = current.diskIO.keys.sorted().compactMap { name in
            guard let a = prev.diskIO[name], let b = current.diskIO[name] else { return nil }
            let ops = max(b.reads - a.reads, 0) + max(b.writes - a.writes, 0)
            let ms = max(b.readMs - a.readMs, 0) + max(b.writeMs - a.writeMs, 0)
            return Device(name: name, read: Double(max(b.readBytes - a.readBytes, 0)) / dt, write: Double(max(b.writeBytes - a.writeBytes, 0)) / dt,
                          iops: Double(ops) / dt, awaitMs: ops > 0 ? Double(ms) / Double(ops) : 0)
        }
        if let a = prev.tcp, let b = current.tcp {
            let sent = b.outSegments - a.outSegments, again = b.retransmitted - a.retransmitted
            tcpRetransmitPercent = sent > 0 && again >= 0 ? Double(again) / Double(sent) * 100 : 0
        }
    }

    private static func cpu(prev: MetricsSnapshot, cur: MetricsSnapshot) -> CPU {
        func pct(_ a: MetricsSnapshot.CPUTimes, _ b: MetricsSnapshot.CPUTimes, _ part: (MetricsSnapshot.CPUTimes) -> Double) -> Double {
            let dt = b.total - a.total
            return dt > 0 ? max(min((part(b) - part(a)) / dt * 100, 100), 0) : 0
        }
        var c = CPU()
        c.total = pct(prev.cpuTotal, cur.cpuTotal, \.busy)
        c.user = pct(prev.cpuTotal, cur.cpuTotal, \.user)
        c.system = pct(prev.cpuTotal, cur.cpuTotal, \.system)
        c.nice = pct(prev.cpuTotal, cur.cpuTotal, \.nice)
        c.iowait = pct(prev.cpuTotal, cur.cpuTotal, \.iowait)
        c.steal = pct(prev.cpuTotal, cur.cpuTotal, \.steal)
        c.cores = zip(prev.cpuCores, cur.cpuCores).map { pct($0, $1, \.busy) }
        return c
    }
}

enum Format {
    static func bytes(_ v: Int64) -> String { ByteCountFormatter.string(fromByteCount: v, countStyle: .binary) }
    static func bytes(_ v: Double) -> String { bytes(Int64(v)) }
    /// Three significant digits, the way the docker CLI rounds: "3.64 G", "28.6 M", "220 K".
    static func precise(_ v: Int64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(v), i = 0
        while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
        let format = i == 0 || value >= 100 ? "%.0f %@" : (value >= 10 ? "%.1f %@" : "%.2f %@")
        return String(format: format, value, units[i])
    }

    /// Short unit form: "23.4 G", "512 M"
    static func short(_ v: Int64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(v), i = 0
        while value >= 1024, i < units.count - 1 { value /= 1024; i += 1 }
        return String(format: value >= 100 || i == 0 ? "%.0f %@" : "%.1f %@", value, units[i])
    }
    static func rate(_ bytesPerSec: Double) -> (String, String) {
        let bits = UserDefaults.standard.bool(forKey: "networkAsBits")
        let units = bits ? ["b/s", "Kb/s", "Mb/s", "Gb/s"] : ["B/s", "K/s", "M/s", "G/s"]
        var v = bits ? bytesPerSec * 8 : bytesPerSec, i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return (String(format: v >= 100 || i == 0 ? "%.0f" : "%.1f", v), units[i])
    }
    static func uptime(_ s: TimeInterval) -> String {
        let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, m = (Int(s) % 3600) / 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) m" }
        return "\(m) m"
    }
}
