import Foundation

/// One JSON object emitted by the docker CLI, with lenient accessors (docker mixes strings and numbers).
struct JSONBag {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }
    init?(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.raw = object
    }

    func string(_ key: String) -> String {
        if let s = raw[key] as? String { return s }
        if let n = raw[key] as? NSNumber { return n.stringValue }
        return ""
    }
    func int(_ key: String) -> Int {
        if let n = raw[key] as? NSNumber { return n.intValue }
        return Int(string(key)) ?? 0
    }
    func int64(_ key: String) -> Int64 {
        if let n = raw[key] as? NSNumber { return n.int64Value }
        return Int64(string(key)) ?? 0
    }
    func double(_ key: String) -> Double {
        if let n = raw[key] as? NSNumber { return n.doubleValue }
        return Double(string(key)) ?? 0
    }
    func bool(_ key: String) -> Bool { (raw[key] as? Bool) ?? (string(key) == "true") }
    func bag(_ key: String) -> JSONBag? { (raw[key] as? [String: Any]).map(JSONBag.init) }
    func bags(_ key: String) -> [JSONBag] { ((raw[key] as? [[String: Any]]) ?? []).map(JSONBag.init) }
    func children(_ key: String) -> [JSONBag] { ((raw[key] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []).map(JSONBag.init) }
}

/// Parses the human-readable sizes and percentages the docker CLI prints.
enum DockerSize {
    /// "3.64GB", "1.13GB (31%)", "8.19kB", "382MiB", "N/A" → bytes
    static func bytes(_ text: String) -> Int64 {
        let head = text.split(separator: "(").first.map(String.init) ?? text
        let value = head.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "N/A", value != "-" else { return 0 }
        let digits = value.prefix { $0.isNumber || $0 == "." || $0 == "," }
        let unit = value.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        let number = Double(digits.replacingOccurrences(of: ",", with: ".")) ?? 0
        let kilo = 1024.0
        let factor: Double
        switch unit {
        case "kb": factor = 1000
        case "mb": factor = 1000 * 1000
        case "gb": factor = 1000 * 1000 * 1000
        case "tb": factor = 1000 * 1000 * 1000 * 1000
        case "kib": factor = kilo
        case "mib": factor = kilo * kilo
        case "gib": factor = kilo * kilo * kilo
        case "tib": factor = kilo * kilo * kilo * kilo
        default: factor = 1
        }
        return Int64(number * factor)
    }

    /// "0.10%" → 0.10
    static func percent(_ text: String) -> Double {
        let clean = text.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        return Double(clean.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// "1.13GB (31%)" → 31
    static func parenthesizedPercent(_ text: String) -> Double {
        guard let open = text.firstIndex(of: "("), let close = text.firstIndex(of: ")"), open < close else { return 0 }
        return percent(String(text[text.index(after: open)..<close]))
    }

    /// "39.7MB / 85.2MB" → (39.7 MB, 85.2 MB) in bytes
    static func pair(_ text: String) -> (Int64, Int64) {
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return (0, 0) }
        return (bytes(parts[0]), bytes(parts[1]))
    }
}

struct DockerEngine: Sendable, Equatable {
    var version = "", apiVersion = "", operatingSystem = "", architecture = "", kernel = ""
    var storageDriver = "", loggingDriver = "", cgroupDriver = "", cgroupVersion = "", hostname = "", socket = ""
    var cpus = 0
    var memory: Int64 = 0
    var containers = 0, running = 0, paused = 0, stopped = 0, images = 0

    var systemLine: String { [operatingSystem, architecture].filter { !$0.isEmpty }.joined(separator: " · ") }
    var cgroupLine: String { [cgroupDriver, cgroupVersion.isEmpty ? "" : "v\(cgroupVersion)"].filter { !$0.isEmpty }.joined(separator: " · ") }
    var resourceLine: String { "\(cpus) CPUs · \(Format.short(memory))" }
    var other: Int { max(containers - running - paused - stopped, 0) }
}

struct DockerDisk: Sendable, Equatable {
    struct Entry: Sendable, Equatable, Identifiable {
        var id: String { kind }
        var kind = ""
        var size: Int64 = 0
        var reclaimable: Int64 = 0
        var reclaimablePercent = 0.0
        var total = 0
        var active = 0
    }
    var images = Entry(kind: "Images")
    var containers = Entry(kind: "Containers")
    var volumes = Entry(kind: "Volumes")
    var buildCache = Entry(kind: "Build Cache")

    var all: [Entry] { [images, containers, volumes, buildCache] }
    var total: Int64 { all.reduce(0) { $0 + $1.size } }
    var reclaimable: Int64 { all.reduce(0) { $0 + $1.reclaimable } }
    var reclaimablePercent: Double { total > 0 ? Double(reclaimable) / Double(total) * 100 : 0 }
}

struct DockerContainer: Identifiable, Hashable, Sendable {
    var id = "", name = "", image = "", state = "", status = "", runningFor = "", createdAt = "", command = ""
    var ports: [String] = []
    var networks: [String] = []
    var mounts: [String] = []
    var project = "", service = ""
    var labels: [String: String] = [:]

    var shortID: String { String(id.prefix(12)) }
    var isRunning: Bool { state == "running" }
    var composeLine: String { project.isEmpty ? "" : (service.isEmpty ? project : "\(project) · \(service)") }
}

struct DockerStats: Sendable, Hashable {
    var id = "", name = ""
    var cpu = 0.0
    var memoryUsed: Int64 = 0, memoryLimit: Int64 = 0
    var memoryPercent = 0.0
    var netRx: Int64 = 0, netTx: Int64 = 0
    var blockRead: Int64 = 0, blockWrite: Int64 = 0
    var pids = 0
}

struct DockerImage: Identifiable, Hashable, Sendable {
    var id = "", repository = "", tag = "", digest = "", createdSince = "", createdAt = ""
    var size: Int64 = 0
    var usedBy: [String] = []

    var reference: String { "\(repository):\(tag)" }
    var shortID: String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
    var isDangling: Bool { repository == "<none>" || tag == "<none>" }
}

struct DockerVolume: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name = "", driver = "", mountpoint = "", scope = ""
    var usedBy: [String] = []
}

struct DockerNetwork: Identifiable, Hashable, Sendable {
    var id = "", name = "", driver = "", scope = "", subnet = "", gateway = ""
    var isInternal = false, isAttachable = false
    var containerNames: [String] = []

    var isBuiltIn: Bool { ["bridge", "host", "none"].contains(name) }
    var shortID: String { String(id.prefix(12)) }
}

struct DockerCompose: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name = "", status = "", configFiles = ""
    var services = 0
    var containerIDs: [String] = []

    var configFileList: [String] { configFiles.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var isRunning: Bool { status.hasPrefix("running") }
}

struct DockerEvent: Identifiable, Hashable, Sendable {
    var id = UUID()
    var type = "", action = "", actor = "", image = ""
    var time = Date()

    var icon: String {
        switch type {
        case "container": "shippingbox"
        case "image": "square.stack.3d.up"
        case "volume": "externaldrive"
        case "network": "globe"
        default: "circle"
        }
    }
}

/// Everything the Docker panel shows, collected with a single shell script.
struct DockerInventory: Sendable {
    var engine = DockerEngine()
    var disk = DockerDisk()
    var containers: [DockerContainer] = []
    var stats: [String: DockerStats] = [:]
    var images: [DockerImage] = []
    var volumes: [DockerVolume] = []
    var networks: [DockerNetwork] = []
    var composes: [DockerCompose] = []

    func stats(for container: DockerContainer) -> DockerStats? { stats[container.shortID] }
    var liveStats: [DockerStats] { containers.filter(\.isRunning).compactMap { stats[$0.shortID] } }
    var containerCPU: Double { liveStats.reduce(0) { $0 + $1.cpu } }
    var containerMemory: Int64 { liveStats.reduce(0) { $0 + $1.memoryUsed } }

    /// Sections are delimited by `##NAME`; every command swallows its own stderr so one failure never shifts the output.
    static let script = """
    echo '##VERSION'; docker version --format "{{json .}}" 2>/dev/null
    echo '##INFO'; docker info --format "{{json .}}" 2>/dev/null
    echo '##DF'; docker system df --format "{{json .}}" 2>/dev/null
    echo '##PS'; docker ps -a --no-trunc --format "{{json .}}" 2>/dev/null
    echo '##STATS'; docker stats --no-stream --format "{{json .}}" 2>/dev/null
    echo '##IMAGES'; docker images --format "{{json .}}" 2>/dev/null
    echo '##VOLUMES'; docker volume ls --format "{{json .}}" 2>/dev/null
    echo '##NETWORKS'; docker network inspect $(docker network ls -q) --format "{{json .}}" 2>/dev/null
    echo '##COMPOSE'; docker compose ls -a --format json 2>/dev/null
    echo '##SOCKET'; docker context inspect --format "{{.Endpoints.docker.Host}}" 2>/dev/null
    """

    static func parse(_ output: String) -> DockerInventory {
        var sections: [String: [String]] = [:]
        var current = ""
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("##") { current = String(line.dropFirst(2)); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { sections[current, default: []].append(trimmed) }
        }
        func objects(_ key: String) -> [JSONBag] { (sections[key] ?? []).compactMap { JSONBag(line: $0) } }
        func object(_ key: String) -> JSONBag? { JSONBag(line: (sections[key] ?? []).joined()) }

        var inventory = DockerInventory()
        inventory.engine = engine(version: object("VERSION"), info: object("INFO"), socket: sections["SOCKET"]?.first ?? "")
        inventory.disk = disk(objects("DF"))
        inventory.containers = objects("PS").map(container)
        for bag in objects("STATS") {
            let entry = stats(bag)
            inventory.stats[entry.id] = entry
        }
        inventory.images = objects("IMAGES").map(image)
        inventory.volumes = objects("VOLUMES").map(volume)
        inventory.networks = objects("NETWORKS").map(network)

        // usedBy links come from the container list, so no extra round trip is needed
        for index in inventory.images.indices {
            let item = inventory.images[index]
            inventory.images[index].usedBy = inventory.containers
                .filter { $0.image == item.reference || $0.image.hasPrefix(item.shortID) || $0.image == item.repository }
                .map(\.name)
        }
        for index in inventory.volumes.indices {
            let name = inventory.volumes[index].name
            inventory.volumes[index].usedBy = inventory.containers.filter { $0.mounts.contains(name) }.map(\.name)
        }

        let byProject = Dictionary(grouping: inventory.containers.filter { !$0.project.isEmpty }, by: \.project)
        inventory.composes = ((try? JSONSerialization.jsonObject(with: Data((sections["COMPOSE"] ?? []).joined().utf8)) as? [[String: Any]]) ?? [])?
            .map(JSONBag.init).map { bag in
                var project = DockerCompose()
                project.name = bag.string("Name")
                project.status = bag.string("Status")
                project.configFiles = bag.string("ConfigFiles")
                let members = byProject[project.name] ?? []
                project.services = Set(members.map(\.service)).count
                project.containerIDs = members.map(\.id)
                return project
            } ?? []
        return inventory
    }

    // MARK: - section parsers

    private static func engine(version: JSONBag?, info: JSONBag?, socket: String) -> DockerEngine {
        var engine = DockerEngine()
        let server = version?.bag("Server")
        engine.version = server?.string("Version") ?? info?.string("ServerVersion") ?? ""
        engine.apiVersion = server?.string("ApiVersion") ?? ""
        engine.architecture = server?.string("Arch") ?? info?.string("Architecture") ?? ""
        engine.kernel = server?.string("KernelVersion") ?? info?.string("KernelVersion") ?? ""
        if let info {
            engine.operatingSystem = info.string("OperatingSystem")
            engine.storageDriver = info.string("Driver")
            engine.loggingDriver = info.string("LoggingDriver")
            engine.cgroupDriver = info.string("CgroupDriver")
            engine.cgroupVersion = info.string("CgroupVersion")
            engine.hostname = info.string("Name")
            engine.cpus = info.int("NCPU")
            engine.memory = info.int64("MemTotal")
            engine.containers = info.int("Containers")
            engine.running = info.int("ContainersRunning")
            engine.paused = info.int("ContainersPaused")
            engine.stopped = info.int("ContainersStopped")
            engine.images = info.int("Images")
        }
        engine.socket = socket.replacingOccurrences(of: "unix://", with: "")
        return engine
    }

    private static func disk(_ bags: [JSONBag]) -> DockerDisk {
        var disk = DockerDisk()
        for bag in bags {
            var entry = DockerDisk.Entry()
            entry.kind = bag.string("Type")
            entry.size = DockerSize.bytes(bag.string("Size"))
            entry.reclaimable = DockerSize.bytes(bag.string("Reclaimable"))
            entry.reclaimablePercent = DockerSize.parenthesizedPercent(bag.string("Reclaimable"))
            entry.total = bag.int("TotalCount")
            entry.active = bag.int("Active")
            switch entry.kind {
            case "Images": disk.images = entry
            case "Containers": disk.containers = entry
            case "Local Volumes": entry.kind = "Volumes"; disk.volumes = entry
            case "Build Cache": disk.buildCache = entry
            default: break
            }
        }
        return disk
    }

    private static func container(_ bag: JSONBag) -> DockerContainer {
        var item = DockerContainer()
        item.id = bag.string("ID")
        item.name = bag.string("Names").split(separator: ",").first.map(String.init) ?? bag.string("Names")
        item.image = bag.string("Image")
        item.state = bag.string("State")
        item.status = bag.string("Status")
        item.runningFor = bag.string("RunningFor")
        item.createdAt = bag.string("CreatedAt")
        item.command = bag.string("Command").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        item.ports = ports(bag.string("Ports"))
        item.networks = bag.string("Networks").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        item.mounts = bag.string("Mounts").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        item.labels = labels(bag.string("Labels"))
        item.project = item.labels["com.docker.compose.project"] ?? ""
        item.service = item.labels["com.docker.compose.service"] ?? ""
        return item
    }

    /// "0.0.0.0:444->443/tcp, [::]:444->443/tcp" → ["444->443/tcp"]
    static func ports(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in raw.split(separator: ",") {
            let entry = part.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            var compact = entry
            if let arrow = entry.range(of: "->") {
                let published = entry[entry.startIndex..<arrow.lowerBound].split(separator: ":").last.map(String.init) ?? ""
                compact = published + entry[arrow.lowerBound...]
            }
            if seen.insert(compact).inserted { result.append(compact) }
        }
        return result
    }

    private static func labels(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    private static func stats(_ bag: JSONBag) -> DockerStats {
        var item = DockerStats()
        item.id = String(bag.string("ID").prefix(12))
        item.name = bag.string("Name")
        item.cpu = DockerSize.percent(bag.string("CPUPerc"))
        let memory = DockerSize.pair(bag.string("MemUsage"))
        item.memoryUsed = memory.0
        item.memoryLimit = memory.1
        item.memoryPercent = DockerSize.percent(bag.string("MemPerc"))
        let net = DockerSize.pair(bag.string("NetIO"))
        item.netRx = net.0
        item.netTx = net.1
        let block = DockerSize.pair(bag.string("BlockIO"))
        item.blockRead = block.0
        item.blockWrite = block.1
        item.pids = bag.int("PIDs")
        return item
    }

    private static func image(_ bag: JSONBag) -> DockerImage {
        var item = DockerImage()
        item.id = bag.string("ID")
        item.repository = bag.string("Repository")
        item.tag = bag.string("Tag")
        item.digest = bag.string("Digest")
        item.createdSince = bag.string("CreatedSince")
        item.createdAt = bag.string("CreatedAt")
        item.size = DockerSize.bytes(bag.string("Size"))
        return item
    }

    private static func volume(_ bag: JSONBag) -> DockerVolume {
        var item = DockerVolume()
        item.name = bag.string("Name")
        item.driver = bag.string("Driver")
        item.mountpoint = bag.string("Mountpoint")
        item.scope = bag.string("Scope")
        return item
    }

    private static func network(_ bag: JSONBag) -> DockerNetwork {
        var item = DockerNetwork()
        item.id = bag.string("Id")
        item.name = bag.string("Name")
        item.driver = bag.string("Driver")
        item.scope = bag.string("Scope")
        item.isInternal = bag.bool("Internal")
        item.isAttachable = bag.bool("Attachable")
        if let config = bag.bag("IPAM")?.bags("Config").first {
            item.subnet = config.string("Subnet")
            item.gateway = config.string("Gateway")
        }
        item.containerNames = bag.children("Containers").map { $0.string("Name") }.filter { !$0.isEmpty }
        return item
    }

    /// `docker events --format "{{json .}}"` lines.
    static func parseEvents(_ output: String) -> [DockerEvent] {
        output.split(separator: "\n").compactMap { line -> DockerEvent? in
            guard let bag = JSONBag(line: String(line)) else { return nil }
            var event = DockerEvent()
            event.type = bag.string("Type")
            event.action = bag.string("Action").isEmpty ? bag.string("status") : bag.string("Action")
            let attributes = bag.bag("Actor")?.bag("Attributes")
            event.actor = attributes?.string("name") ?? ""
            event.image = attributes?.string("image") ?? bag.string("from")
            event.time = Date(timeIntervalSince1970: bag.double("time"))
            if event.actor.isEmpty { event.actor = String((bag.bag("Actor")?.string("ID") ?? "").prefix(12)) }
            return event.action.isEmpty ? nil : event
        }
    }
}
