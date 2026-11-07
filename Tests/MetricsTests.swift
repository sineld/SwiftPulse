import Testing
import Foundation
@testable import SwiftPulse

struct MetricsTests {
    static let sample = """
    ##HOST
    myhost
    6.8.0-40-generic
    4
    Ubuntu 24.04 LTS
    ##CPU
    cpu  100 0 50 800 20 0 10 5
    cpu0 25 0 12 200 5 0 2 1
    cpu1 25 0 13 200 5 0 3 1
    cpu2 25 0 12 200 5 0 2 1
    cpu3 25 0 13 200 5 0 3 2
    ##MEM
    MemTotal:       16000000 kB
    MemFree:         2000000 kB
    MemAvailable:   10000000 kB
    Buffers:          500000 kB
    Cached:          3000000 kB
    SwapTotal:       4000000 kB
    SwapFree:        3000000 kB
    ##LOAD
    0.50 0.60 0.70 1/200 12345
    ##UPTIME
    86400.50 300000.00
    ##NET
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo: 1000 10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0
      eth0: 5000000 100 0 0 0 0 0 0 2000000 50 0 0 0 0 0 0
      eth1: 1000000 10 0 0 0 0 0 0 500000 5 0 0 0 0 0 0
    docker0: 9000000 10 0 0 0 0 0 0 9000000 5 0 0 0 0 0 0
    tailscale0: 7000000 10 0 0 0 0 0 0 7000000 5 0 0 0 0 0 0
    ##ROUTE
    1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.5 uid 1000
    ##DISK
    Filesystem     1024-blocks      Used Available Capacity Mounted on
    /dev/sda1        97656250  39062500  58593750  40% /
    tmpfs             1000000         0   1000000   0% /run
    /dev/sdb1       195312500  48828125 146484375  25% /data
    overlay          97656250  39062500  58593750  40% /var/lib/docker/overlay2/abc/merged
    /dev/sdb1       195312500  48828125 146484375  25% /srv/bind
    /dev/loop0          65536     65536         0 100% /snap/core/123
    ##DISKIO
       8       0 sda 100 0 2048 0 50 0 1024 0 0 0 0 0 0 0 0 0 0
       8       1 sda1 100 0 2048 0 50 0 1024 0 0 0 0 0 0 0 0 0 0
       7       0 loop0 1 0 8 0 0 0 0 0 0 0 0 0 0 0 0 0 0
     179       0 mmcblk0 10 0 16 0 0 0 0 0 0 0 0 0 0 0 0 0 0
     179       1 mmcblk0p1 10 0 16 0 0 0 0 0 0 0 0 0 0 0 0 0 0
     259       0 nvme0n1 10 0 16 0 0 0 0 0 0 0 0 0 0 0 0 0 0
     259       1 nvme0n1p1 10 0 16 0 0 0 0 0 0 0 0 0 0 0 0 0 0
       9       0 md0 10 0 16 0 0 0 0 0 0 0 0 0 0 0 0 0 0
     253       0 dm-0 10 0 16 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    ##TEMP
    45000
    ##PS
        PID USER     %CPU %MEM   RSS COMMAND
        123 root      1.5  0.2 20480 nginx
        456 ubuntu   10.0  1.0 102400 node
    """

    @Test func parsesEverySection() {
        let s = MetricsCollector.parse(Self.sample)
        #expect(s.hostname == "myhost")
        #expect(s.kernel == "6.8.0-40-generic")
        #expect(s.coreCount == 4)
        #expect(s.osName == "Ubuntu 24.04 LTS")
        #expect(s.cpuCores.count == 4)
        #expect(s.cpuTotal.idle == 800)
        #expect(s.memTotal == 16_000_000 * 1024)
        #expect(s.memAvailable == 10_000_000 * 1024)
        #expect(s.memCached == 3_500_000 * 1024)      // Cached + Buffers
        #expect(s.swapTotal == 4_000_000 * 1024)
        #expect(s.load == [0.5, 0.6, 0.7])
        #expect(s.uptime == 86400.5)
        #expect(s.net["lo"] == nil)                   // loopback excluded
        #expect(s.net["eth0"]?.rx == 5_000_000)
        #expect(s.net["eth0"]?.tx == 2_000_000)
        #expect(s.primaryInterface == "eth0")
        #expect(s.physicalInterfaces == ["eth0", "eth1"])      // docker0 and tailscale0 would count bytes twice
        #expect(s.traffic.rx == 6_000_000 && s.traffic.tx == 2_500_000)
        #expect(s.publicIP == "10.0.0.5")
        #expect(s.disks.map(\.mount) == ["/", "/data"]) // no tmpfs, container, snap or second bind mount
        #expect(s.disks[0].used == 40_000_000_000)
        #expect(Set(s.diskIO.keys) == ["sda", "mmcblk0", "nvme0n1"]) // partitions, loop, RAID and LVM devices skipped
        let sdaRead: Int64? = s.diskIO["sda"]?.readBytes
        #expect(sdaRead == 1_048_576)                  // 2048 sectors × 512
        #expect(s.temperatureC == 45)
        #expect(s.processes.map(\.pid) == [123, 456])
        #expect(s.processes[1].command == "node")
        #expect(s.processes[1].rssBytes == 102400 * 1024)
    }

    @Test func ratesComeFromTwoSnapshots() {
        var first = MetricsCollector.parse(Self.sample)
        first.takenAt = Date(timeIntervalSince1970: 1000)
        var second = first
        second.takenAt = Date(timeIntervalSince1970: 1010)
        // 10 s later: 500 more jiffies, 250 of them busy (user) → 50 % CPU
        second.cpuTotal = .init(user: 350, nice: 0, system: 50, idle: 1050, iowait: 20, irq: 0, softirq: 10, steal: 5)
        second.net["eth0"] = .init(rx: 5_000_000 + 10_240, tx: 2_000_000 + 2_048)
        second.diskIO["sda"] = .init(readBytes: 2048 * 512 + 4096 * 10, writeBytes: 1024 * 512)

        let previous = MachineStatus(current: first, previous: nil)
        let status = MachineStatus(current: second, previous: previous)
        #expect(abs(status.cpu.total - 50) < 0.01)
        #expect(abs(status.cpu.user - 50) < 0.01)
        #expect(abs(status.network.rx - 1024) < 0.01)
        #expect(abs(status.network.tx - 204.8) < 0.01)
        #expect(abs(status.diskIO.rx - 4096) < 0.01)
        #expect(status.diskIO.tx == 0)
        #expect(status.loadHistory.count == 2)
        #expect(abs(status.memPercent - 37.5) < 0.01)  // (16 - 10) / 16
    }

    @Test func trafficSumsPhysicalInterfacesAndIgnoresResets() {
        var first = MetricsCollector.parse(Self.sample)
        first.takenAt = Date(timeIntervalSince1970: 1000)
        var second = first
        second.takenAt = Date(timeIntervalSince1970: 1010)
        second.net["eth0"] = .init(rx: 5_000_000 + 1000, tx: 2_000_000)
        second.net["eth1"] = .init(rx: 1_000_000 + 9000, tx: 100)   // tx went back: the counter was reset
        second.net["docker0"] = .init(rx: 99_000_000, tx: 99_000_000) // virtual: ignored
        let status = MachineStatus(current: second, previous: MachineStatus(current: first, previous: nil))
        #expect(abs(status.network.rx - 1000) < 0.01)
        #expect(status.network.tx == 0)
    }

    @Test func sysfsDecidesWhichInterfacesAreCards() {
        let tunnels = Self.sample.replacingOccurrences(of: "##ROUTE", with: """
        ##NIC
        /sys/class/net/eth0/device
        ##ROUTE
        """).replacingOccurrences(of: "docker0:", with: "as0t0:")
        let s = MetricsCollector.parse(tunnels)
        #expect(s.nics == ["eth0"])
        #expect(s.physicalInterfaces == ["eth0"]) // eth1 has no device here, and as0t0 is an OpenVPN tunnel
        #expect(MetricsCollector.isSystemMount(filesystem: "log2ram", mount: "/var/log"))
        #expect(MetricsCollector.isSystemMount(filesystem: "folder2ram", mount: "/var/log")) // OpenMediaVault
    }

    @Test func wholeDisksAndSystemMounts() {
        let names = ["sda", "sda1", "xvda", "vda1", "mmcblk0", "mmcblk0p2", "nvme0n1", "nvme0n1p1", "md127", "dm-1", "zram0", "sr0"]
        #expect(names.filter { MetricsCollector.isWholeDisk($0, among: names) } == ["sda", "xvda", "vda1", "mmcblk0", "nvme0n1"])
        #expect(MetricsCollector.isSystemMount(filesystem: "/dev/sda1", mount: "/") == false)
        #expect(MetricsCollector.isSystemMount(filesystem: "/dev/sda1", mount: "/running-jobs") == false)
        #expect(MetricsCollector.isSystemMount(filesystem: "/dev/sda1", mount: "/run/media/usb"))
        #expect(MetricsCollector.isSystemMount(filesystem: "shm", mount: "/dev/shm"))
    }

    @Test func monitorsBackOffAndRestWhenUnseen() {
        #expect(MachineMonitor.delay(failures: 0, quickRetry: false, interval: 5) == 5)
        #expect(MachineMonitor.delay(failures: 1, quickRetry: true, interval: 5) == 1)   // a dropped connection
        #expect(MachineMonitor.delay(failures: 2, quickRetry: false, interval: 5) == 10)
        #expect(MachineMonitor.delay(failures: 9, quickRetry: false, interval: 5) == 30)
        let now = Date()
        #expect(MachineMonitor.shouldPoll(visible: true, lastDemand: .distantPast, now: now))
        #expect(!MachineMonitor.shouldPoll(visible: false, lastDemand: .distantPast, now: now))
        #expect(MachineMonitor.shouldPoll(visible: false, lastDemand: now.addingTimeInterval(-30), now: now)) // an agent asked
        #expect(!MachineMonitor.shouldPoll(visible: false, lastDemand: now.addingTimeInterval(-90), now: now))
    }

    @Test func devicesAndTCPComeFromTwoPolls() {
        var first = MetricsCollector.parse(Self.sample + """

        ##TCP
        Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors
        Tcp: 1 200 120000 -1 100 50 3 2 12 10000 20000 100 0 5 0
        """)
        #expect(first.tcp?.established == 12 && first.tcp?.outSegments == 20000 && first.tcp?.failedAttempts == 3)
        #expect(first.diskIO["sda"]?.reads == 100 && first.diskIO["sda"]?.writes == 50)
        first.takenAt = Date(timeIntervalSince1970: 1000)
        var second = first
        second.takenAt = Date(timeIntervalSince1970: 1010)
        second.diskIO["sda"] = .init(readBytes: 2048 * 512, writeBytes: 1024 * 512, reads: 150, writes: 100, readMs: 200, writeMs: 300)
        second.tcp = .init(established: 12, outSegments: 21000, retransmitted: 110, failedAttempts: 3)
        let status = MachineStatus(current: second, previous: MachineStatus(current: first, previous: nil))
        let sda = status.devices.first { $0.name == "sda" }
        #expect(sda?.iops == 10)       // 100 requests in 10 s
        #expect(sda?.awaitMs == 5)     // 500 ms over 100 requests
        #expect(status.tcpRetransmitPercent == 1) // 10 of 1000 segments
    }

    @Test func formatting() {
        #expect(Format.short(1024 * 1024 * 1536) == "1.5 G")
        #expect(Format.short(512) == "512 B")
        #expect(Format.uptime(90_000) == "1 d 1 h")
        #expect(Format.uptime(3_700) == "1 h 1 m")
        UserDefaults.standard.set(false, forKey: "networkAsBits")
        #expect(Format.rate(1536) == ("1.5", "K/s"))
    }
}

struct ProcessListTests {
    @Test func psLinesKeepTheWholeCommandLine() {
        let rows = ProcessesSheet.parse("""
              1 root      0.0  0.1 12345 /sbin/init splash
           4242 www-data 12.5  3.4 204800 php-fpm: pool www   --nodaemonize
        error: unsupported option
        """)
        #expect(rows.map(\.pid) == [1, 4242])
        #expect(rows[1].command == "php-fpm: pool www   --nodaemonize")
        #expect(rows[1].rssBytes == 204800 * 1024 && rows[1].cpu == 12.5 && rows[1].user == "www-data")
    }
}

struct DarwinMetricsTests {
    @Test func macOSSectionsParseLikeLinuxOnes() {
        let s = MetricsCollector.parse("""
        ##HOST
        Mac.lan
        27.0.0
        16
        macOS 27.0.1
        ##CPUPCT
        CPU usage: 3.5% user, 3.26% sys, 93.67% idle
        ##MEM
        MemTotal: 67108864 kB
        MemFree: 35263840 kB
        MemAvailable: 45455152 kB
        Cached: 7816816 kB
        SwapTotal: 0 kB
        SwapFree: 0 kB
        ##LOAD
         3.24 3.07 2.60
        ##UPTIME
        1133434
        ##NET


        lo0: 100 0 0 0 0 0 0 0 100 0 0 0 0 0 0 0
        en0: 72284584516 0 0 0 0 0 0 0 10898011799 0 0 0 0 0 0 0
        bridge0: 5 0 0 0 0 0 0 0 5 0 0 0 0 0 0 0
        utun12: 67201848 0 0 0 0 0 0 0 1962949626 0 0 0 0 0 0 0
        ##NIC
        /sys/class/net/en0/device
        /sys/class/net/bridge0/device
        ##ROUTE
        1.1.1.1 dev en0 src 192.168.2.169
        ##DISK
        Filesystem 1024-blocks Used Available Capacity Mounted on
        /dev/disk3s1s1 971350180 13335216 326086352 4% /
        devfs 231 231 0 100% /dev
        /dev/disk3s6 971350180 24 326086352 1% /System/Volumes/VM
        /dev/disk3s5 971350180 619575612 326086352 66% /System/Volumes/Data
        /dev/disk5s1 17160192 16666636 449384 98% /Library/Developer/CoreSimulator/Volumes/iOS_23B80
        /dev/disk20s1 976762584 500000000 476762584 52% /Volumes/Backup
        ##PS
          PID USER              %CPU %MEM    RSS COMM
          421 _windowserver     35.1  0.4 245408 WindowServer
        13987 alice              1.4  0.6 426912 Google Chrome Helper (Aperitif Renderer)
        """)
        #expect(s.osName == "macOS 27.0.1" && s.coreCount == 16)
        #expect(s.cpuPercent?.user == 3.5 && s.cpuPercent?.system == 3.26)
        #expect(s.memTotal == 67_108_864 * 1024 && s.memAvailable == 45_455_152 * 1024)
        #expect(s.physicalInterfaces == ["en0"]) // bridge0 is a hardware port on macOS, but a bridge
        #expect(s.disks.map(\.mount) == ["/", "/Volumes/Backup"])
        #expect(s.disks[0].used == 619_575_612 * 1024) // the Data volume, not the sealed system snapshot
        #expect(s.processes.last?.command == "Google Chrome Helper (Aperitif Renderer)")
        let status = MachineStatus(current: s, previous: nil)
        #expect(abs(status.cpu.total - 6.76) < 0.001) // no previous poll needed on macOS
    }

    @Test(arguments: [true, false])
    func bothScriptsExitZeroEvenWhenASectionFails(processes: Bool) throws {
        // Linux's branch on a Mac: most /proc and /sys reads fail, as a missing thermal sensor does on a VM.
        let linux = MetricsCollector.script(processes: processes).replacingOccurrences(of: #"[ "$(uname -s)" = Darwin ]"#, with: "false")
        for script in [MetricsCollector.script(processes: processes), linux] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }

    @Test func theScriptRunsOnThisMac() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", MetricsCollector.script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let s = MetricsCollector.parse(output)
        #expect(s.osName.hasPrefix("macOS") && s.coreCount > 0 && s.memTotal > 0)
        #expect(!MetricsCollector.script(processes: false).contains("##PS") && MetricsCollector.script(processes: true).contains("##PS"))
        #expect(MetricsCollector.script(processes: false).contains("##DISK")) // only the process list goes
        #expect(s.cpuPercent != nil && s.uptime > 0 && s.uptime < 400 * 86400)
        #expect(s.disks.first?.mount == "/" && !s.physicalInterfaces.isEmpty && !s.processes.isEmpty)
    }
}
