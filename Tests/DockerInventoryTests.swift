import Testing
import Foundation
@testable import SwiftPulse

/// Fixture trimmed from a real Docker 29.3.1 host (`ubuntu@…:2198`), keeping every field the parser reads.
private let fixture = """
##VERSION
{"Client":{"Version":"29.3.1"},"Server":{"Version":"29.3.1","ApiVersion":"1.54","Os":"linux","Arch":"arm64","KernelVersion":"6.17.0-1011-oracle"}}
##INFO
{"ServerVersion":"29.3.1","OperatingSystem":"Ubuntu 24.04.4 LTS","Architecture":"aarch64","KernelVersion":"6.17.0-1011-oracle","Driver":"overlayfs","LoggingDriver":"json-file","CgroupDriver":"systemd","CgroupVersion":"2","NCPU":4,"MemTotal":25139523584,"Containers":3,"ContainersRunning":2,"ContainersPaused":0,"ContainersStopped":1,"Images":3,"Name":"web-01"}
##DF
{"Active":"2","Reclaimable":"2.697GB (68%)","Size":"3.91GB","TotalCount":"3","Type":"Images"}
{"Active":"2","Reclaimable":"0B (0%)","Size":"225.3kB","TotalCount":"2","Type":"Containers"}
{"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Local Volumes"}
{"Active":"0","Reclaimable":"0B","Size":"0B","TotalCount":"0","Type":"Build Cache"}
##PS
{"ID":"934df09d8d6d15b698229aa8e604aff4b4b3e7b99c5396dd6d075d8c6f968316","Names":"openresty","Image":"1panel/openresty:1.31.1.1-2-4-noble","State":"running","Status":"Up 13 days","RunningFor":"13 days ago","CreatedAt":"2026-08-25 23:00:28 +0300","Command":"\\"/usr/local/openrest…\\"","Ports":"","Networks":"1panel-network","Mounts":"","Labels":"com.docker.compose.project=openresty,com.docker.compose.service=openresty"}
{"ID":"cde63d0c1cb83b8ac91ad9f2c01783f2f3a78920388cdc94332e73ae87674606","Names":"openvpn","Image":"openvpn/openvpn-as:latest","State":"running","Status":"Up 4 months","RunningFor":"4 months ago","CreatedAt":"2026-05-02 10:11:12 +0300","Command":"\\"/init\\"","Ports":"0.0.0.0:943->943/tcp, [::]:943->943/tcp, 0.0.0.0:1194->1194/udp, [::]:1194->1194/udp, 0.0.0.0:444->443/tcp, [::]:444->443/tcp","Networks":"host","Mounts":"vpn-data","Labels":"com.docker.compose.project=openvpn,com.docker.compose.service=openvpn"}
##STATS
{"BlockIO":"8.19kB / 22.5MB","CPUPerc":"0.01%","Container":"934df09d8d6d","ID":"934df09d8d6d","MemPerc":"0.12%","MemUsage":"28.64MiB / 23.41GiB","Name":"openresty","NetIO":"0B / 0B","PIDs":"5"}
{"BlockIO":"88.2MB / 41.5MB","CPUPerc":"0.09%","Container":"cde63d0c1cb8","ID":"cde63d0c1cb8","MemPerc":"1.59%","MemUsage":"381.4MiB / 23.41GiB","Name":"openvpn","NetIO":"41.7MB / 89.5MB","PIDs":"20"}
##IMAGES
{"Containers":"1","CreatedAt":"2026-08-18 13:49:06 +0300 +03","CreatedSince":"3 weeks ago","Digest":"<none>","ID":"1f3316a78af3","Repository":"1panel/openresty","Size":"1.4GB","Tag":"1.31.1.1-2-4-noble"}
{"Containers":"0","CreatedAt":"2025-12-02 09:00:00 +0300 +03","CreatedSince":"9 months ago","Digest":"<none>","ID":"ee8c5117c291","Repository":"1panel/openresty","Size":"1.21GB","Tag":"1.27.1.2-5-1-focal"}
{"Containers":"1","CreatedAt":"2025-10-02 09:00:00 +0300 +03","CreatedSince":"11 months ago","Digest":"<none>","ID":"ca8b271cdb31","Repository":"<none>","Size":"1.3GB","Tag":"<none>"}
##VOLUMES
{"Driver":"local","Labels":"","Mountpoint":"/var/lib/docker/volumes/vpn-data/_data","Name":"vpn-data","Scope":"local"}
{"Driver":"local","Labels":"","Mountpoint":"/var/lib/docker/volumes/orphan/_data","Name":"orphan","Scope":"local"}
##NETWORKS
{"Name":"1panel-network","Id":"a1b2c3d4e5f60000","Driver":"bridge","Scope":"local","Internal":false,"Attachable":false,"IPAM":{"Driver":"default","Config":[{"Subnet":"172.18.0.0/16","Gateway":"172.18.0.1"}]},"Containers":{"934df09d8d6d":{"Name":"openresty"}}}
{"Name":"bridge","Id":"ffffffffffff0000","Driver":"bridge","Scope":"local","Internal":false,"Attachable":false,"IPAM":{"Driver":"default","Config":[{"Subnet":"172.17.0.0/16","Gateway":"172.17.0.1"}]},"Containers":{}}
##COMPOSE
[{"Name":"openresty","Status":"running(1)","ConfigFiles":"/opt/1panel/apps/openresty/openresty/docker-compose.yml"},{"Name":"openvpn","Status":"running(1)","ConfigFiles":"/opt/1panel/apps/openvpn/openvpn/docker-compose.yml"}]
##SOCKET
unix:///var/run/docker.sock
"""

struct DockerInventoryTests {
    private let inventory = DockerInventory.parse(fixture)

    @Test func enginePrefersServerArchAndInfoCounts() {
        let engine = inventory.engine
        #expect(engine.version == "29.3.1")
        #expect(engine.apiVersion == "1.54")
        #expect(engine.operatingSystem == "Ubuntu 24.04.4 LTS")
        #expect(engine.architecture == "arm64")          // Server.Arch, not info's "aarch64"
        #expect(engine.systemLine == "Ubuntu 24.04.4 LTS · arm64")
        #expect(engine.storageDriver == "overlayfs")
        #expect(engine.cgroupLine == "systemd · v2")
        #expect(engine.cpus == 4)
        #expect(engine.memory == 25_139_523_584)
        #expect(engine.containers == 3)
        #expect(engine.running == 2)
        #expect(engine.stopped == 1)
        #expect(engine.other == 0)
        #expect(engine.socket == "/var/run/docker.sock")  // unix:// prefix stripped
    }

    @Test func diskUsageKeepsReclaimableSeparately() {
        let disk = inventory.disk
        #expect(disk.images.size == 3_910_000_000)
        #expect(disk.images.reclaimable == 2_697_000_000)
        #expect(disk.images.reclaimablePercent == 68)
        #expect(disk.containers.size == 225_300)
        #expect(disk.volumes.kind == "Volumes")           // "Local Volumes" is renamed for display
        #expect(disk.total == 3_910_225_300)
        #expect(Int(disk.reclaimablePercent.rounded()) == 69)
    }

    @Test func containersCarryComposeLabelsAndDedupedPorts() throws {
        #expect(inventory.containers.count == 2)
        let openvpn = try #require(inventory.containers.first { $0.name == "openvpn" })
        #expect(openvpn.shortID == "cde63d0c1cb8")
        #expect(openvpn.isRunning)
        #expect(openvpn.project == "openvpn")
        #expect(openvpn.service == "openvpn")
        #expect(openvpn.composeLine == "openvpn · openvpn")
        // both IPv4 and IPv6 bindings collapse into one chip per published port
        #expect(openvpn.ports == ["943->943/tcp", "1194->1194/udp", "444->443/tcp"])
        #expect(openvpn.networks == ["host"])
        #expect(openvpn.mounts == ["vpn-data"])
        let openresty = try #require(inventory.containers.first { $0.name == "openresty" })
        #expect(openresty.ports.isEmpty)
        #expect(openresty.mounts.isEmpty)
    }

    @Test func statsAreKeyedByShortContainerID() throws {
        let openvpn = try #require(inventory.containers.first { $0.name == "openvpn" })
        let stats = try #require(inventory.stats(for: openvpn))
        #expect(stats.cpu == 0.09)
        #expect(stats.memoryPercent == 1.59)
        #expect(stats.memoryUsed == 399_926_886)          // 381.4 MiB
        #expect(stats.netRx == 41_700_000)
        #expect(stats.netTx == 89_500_000)
        #expect(stats.blockRead == 88_200_000)
        #expect(stats.blockWrite == 41_500_000)
        #expect(stats.pids == 20)
        #expect(inventory.liveStats.count == 2)
        #expect(abs(inventory.containerCPU - 0.10) < 0.0001)
        #expect(inventory.containerMemory == 399_926_886 + 30_031_216)
    }

    @Test func imagesLinkToTheirContainersAndFlagDangling() throws {
        #expect(inventory.images.count == 3)
        let used = try #require(inventory.images.first { $0.tag == "1.31.1.1-2-4-noble" })
        #expect(used.usedBy == ["openresty"])
        #expect(!used.isDangling)
        #expect(used.size == 1_400_000_000)
        let unused = try #require(inventory.images.first { $0.tag == "1.27.1.2-5-1-focal" })
        #expect(unused.usedBy.isEmpty)
        #expect(inventory.images.filter(\.isDangling).count == 1)
    }

    @Test func volumesAndNetworksResolveTheirUsers() throws {
        let volume = try #require(inventory.volumes.first { $0.name == "vpn-data" })
        #expect(volume.usedBy == ["openvpn"])
        #expect(try #require(inventory.volumes.first { $0.name == "orphan" }).usedBy.isEmpty)

        let panel = try #require(inventory.networks.first { $0.name == "1panel-network" })
        #expect(panel.subnet == "172.18.0.0/16")
        #expect(panel.gateway == "172.18.0.1")
        #expect(panel.containerNames == ["openresty"])
        #expect(!panel.isBuiltIn)
        let bridge = try #require(inventory.networks.first { $0.name == "bridge" })
        #expect(bridge.isBuiltIn)
        #expect(bridge.containerNames.isEmpty)
    }

    @Test func composeProjectsCountTheirServices() throws {
        #expect(inventory.composes.count == 2)
        let project = try #require(inventory.composes.first { $0.name == "openvpn" })
        #expect(project.status == "running(1)")
        #expect(project.isRunning)
        #expect(project.services == 1)
        #expect(project.configFileList == ["/opt/1panel/apps/openvpn/openvpn/docker-compose.yml"])
        #expect(project.containerIDs.count == 1)
    }

    @Test func eventsParseActorAndTime() throws {
        let line = #"{"status":"start","id":"cde63d0c1cb8","Type":"container","Action":"start","Actor":{"ID":"cde63d0c1cb8","Attributes":{"name":"openvpn","image":"openvpn/openvpn-as:latest"}},"time":1757308800}"#
        let events = DockerInventory.parseEvents(line)
        #expect(events.count == 1)
        #expect(events[0].type == "container")
        #expect(events[0].action == "start")
        #expect(events[0].actor == "openvpn")
        #expect(events[0].image == "openvpn/openvpn-as:latest")
        #expect(events[0].time == Date(timeIntervalSince1970: 1757308800))
        #expect(DockerInventory.parseEvents("not json").isEmpty)
    }

    @Test func sizeParsingCoversDockerUnits() {
        #expect(DockerSize.bytes("3.91GB") == 3_910_000_000)
        #expect(DockerSize.bytes("23.41GiB") == 25_136_296_099)
        #expect(DockerSize.bytes("225.3kB") == 225_300)
        #expect(DockerSize.bytes("0B") == 0)
        #expect(DockerSize.bytes("N/A") == 0)
        #expect(DockerSize.percent("0.09%") == 0.09)
        #expect(DockerSize.parenthesizedPercent("2.697GB (68%)") == 68)
        let pair = DockerSize.pair("41.7MB / 89.5MB")
        #expect(pair.0 == 41_700_000)
        #expect(pair.1 == 89_500_000)
    }

    @Test func preciseFormattingMatchesDockerRounding() {
        #expect(Format.precise(3_910_225_300) == "3.64 G")
        #expect(Format.precise(225_300) == "220 K")
        #expect(Format.precise(30_031_216) == "28.6 M")
        #expect(Format.precise(512) == "512 B")
    }

    @Test func emptyOutputYieldsEmptyInventory() {
        let empty = DockerInventory.parse("")
        #expect(empty.containers.isEmpty)
        #expect(empty.engine.version.isEmpty)
        #expect(empty.disk.total == 0)
    }
}
