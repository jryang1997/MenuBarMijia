import Foundation
import Testing
@testable import MijiaCore

struct HADiscoveryTests {
    @Test("Parses mDNS _home-assistant._tcp zone output with UTF-8 and DNS-SD escaped names")
    func parseMDNSZoneRecords() {
        let zoneOutput = """
        Browsing for _home-assistant._tcp.local.
        DATE: ---Wed 21 Oct 2026---
        15:06:57.721  ...STARTING...
        _home-assistant._tcp                            PTR     我的家._home-assistant._tcp
        我的家._home-assistant._tcp                  SRV     0 0 8123 f7d5b92ef26b41ce9eba8980bdcb9a00.local. ; Replace with unicast FQDN
        我的家._home-assistant._tcp                  TXT     "location_name=我的家" "uuid=f7d5b92ef26b41ce9eba8980bdcb9a00" "version=2026.10.1" "external_url=" "internal_url=http://10.10.1.4:8123" "base_url=http://10.10.1.4:8123"
        """

        let found = HADiscovery.parseMDNSZoneOutput(zoneOutput) { _ in nil }
        #expect(found.count == 1)
        #expect(found.first?.baseURL == "http://10.10.1.4:8123")
        #expect(found.first?.locationName == "我的家")
        #expect(found.first?.version == "2026.10.1")
        #expect(found.first?.uuid == "f7d5b92ef26b41ce9eba8980bdcb9a00")
        #expect(found.first?.displaySummary == "我的家 (10.10.1.4:8123 · v2026.10.1)")
        #expect(found.first?.securityProfileURL?.absoluteString == "http://10.10.1.4:8123/profile/security")
    }

    @Test("Unescapes DNS-SD decimal byte escapes and resolves SRV target host when internal_url is empty")
    func unescapeAndResolveSRVTarget() {
        // \230\136\145\231\154\132\229\174\182 is UTF-8 for "我的家", \032 is ASCII space
        #expect(HADiscovery.unescapeDNSSD(#"\230\136\145\231\154\132\229\174\182"#) == "我的家")
        #expect(HADiscovery.unescapeDNSSD(#"Home\032Assistant"#) == "Home Assistant")

        let zoneWithoutInternalURL = """
        _home-assistant._tcp                            PTR     Home\\032Assistant._home-assistant._tcp
        Home\\032Assistant._home-assistant._tcp         SRV     0 0 8123 ha-nas.local.
        Home\\032Assistant._home-assistant._tcp         TXT     "location_name=书房中枢" "version=2026.9.0" "internal_url=http://homeassistant.local:8123"
        """

        let resolved = HADiscovery.parseMDNSZoneOutput(zoneWithoutInternalURL) { host in
            host == "ha-nas.local" ? "192.168.31.88" : nil
        }
        #expect(resolved.count == 1)
        #expect(resolved.first?.baseURL == "http://192.168.31.88:8123")
        #expect(resolved.first?.locationName == "书房中枢")
        #expect(resolved.first?.version == "2026.9.0")
    }

    @Test("Parses ARP table private LAN IPv4 addresses and validates Home Assistant manifest.json")
    func arpAndManifestValidation() {
        let arpSample = """
        ? (10.10.1.1) at 60:be:b4:8:e4:19 on en0 ifscope [ethernet]
        ? (10.10.1.4) at 0:11:32:f7:71:4b on en0 ifscope [ethernet]
        ? (10.10.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        ? (169.254.169.254) at 60:be:b4:8:e4:19 on en0 [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        ? (192.168.50.12) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
        """
        let ips = HADiscovery.parseARPTableHosts(arpSample)
        #expect(ips == ["10.10.1.1", "10.10.1.4", "192.168.50.12"])

        let validManifest = Data(##"{"name":"Home Assistant","short_name":"Home Assistant","theme_color":"#2980b9"}"##.utf8)
        let invalidManifest = Data(#"{"name":"Synology DiskStation"}"#.utf8)
        #expect(HADiscovery.isHomeAssistantManifest(validManifest) == true)
        #expect(HADiscovery.isHomeAssistantManifest(invalidManifest) == false)

        let mdnsInst = HADiscoveredInstance(baseURL: "http://10.10.1.4:8123", locationName: "我的家", version: "2026.10.1", uuid: "u1", source: "mDNS")
        let httpInst = HADiscoveredInstance(baseURL: "http://10.10.1.4:8123", locationName: "Home Assistant", source: "HTTP")
        let merged = HADiscovery.mergeInstances(mdns: [mdnsInst], probed: [httpInst])
        #expect(merged.count == 1)
        #expect(merged.first?.locationName == "我的家")
        #expect(merged.first?.version == "2026.10.1")
    }

    @Test("HomeStore applies discovered LAN Home Assistant instance to serverURLString")
    @MainActor
    func storeAppliesDiscoveredHA() {
        let suite = "test.ha.discovery.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let store = HomeStore(provider: MockHomeProvider(), defaultsSuiteName: suite)
        #expect(store.serverURLString == KeychainHelper.defaultNASURL)

        let discovered = HADiscoveredInstance(
            baseURL: "http://10.10.1.4:8123/",
            locationName: "我的群晖之家",
            version: "2026.10.1",
            uuid: "f7d5b92ef26b41ce9eba8980bdcb9a00"
        )
        store.applyDiscoveredHAInstance(discovered, reconnectProvider: false)

        #expect(store.serverURLString == "http://10.10.1.4:8123")
        #expect(store.serverHostSummary == "10.10.1.4")
        #expect(store.homeName == "我的群晖之家")
        #expect(store.discoveredHAInstances.first?.baseURL == "http://10.10.1.4:8123")
    }

    @Test("HADiscovery.discoverOnLAN finds live Home Assistant on LAN when HA_RUN_LIVE_TEST=1 is set")
    func liveLANDiscovery() async throws {
        guard ProcessInfo.processInfo.environment["HA_RUN_LIVE_TEST"] == "1" else { return }
        let found = await HADiscovery.discoverOnLAN()
        print("Found instances (no hint): \(found)")
        let first = try #require(found.first)
        #expect(first.baseURL == "http://10.10.1.4:8123")
        #expect(!first.locationName.isEmpty)
    }
}
