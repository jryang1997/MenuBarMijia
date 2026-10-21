import Foundation
import os
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Discovered Home Assistant Instance Model

public struct HADiscoveredInstance: Equatable, Sendable, Identifiable {
    public var baseURL: String
    public var locationName: String
    public var version: String?
    public var uuid: String?
    public var source: String

    public var id: String { baseURL }

    public var hostAndPort: String {
        baseURL
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    public var displaySummary: String {
        if let version, !version.isEmpty {
            return "\(locationName) (\(hostAndPort) · v\(version))"
        }
        return "\(locationName) (\(hostAndPort))"
    }

    public var securityProfileURL: URL? {
        URL(string: "\(baseURL)/profile/security")
    }

    public init(
        baseURL: String,
        locationName: String = "Home Assistant",
        version: String? = nil,
        uuid: String? = nil,
        source: String = "mDNS"
    ) {
        self.baseURL = HAWebSocketProvider.normalizeBaseURL(baseURL)
        let trimmedName = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.locationName = trimmedName.isEmpty ? "Home Assistant" : trimmedName
        let trimmedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.version = trimmedVersion.isEmpty ? nil : trimmedVersion
        let trimmedUUID = uuid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.uuid = trimmedUUID.isEmpty ? nil : trimmedUUID
        self.source = source
    }
}

// MARK: - Home Assistant LAN Auto-Discovery (mDNS + ARP/HTTP Manifest Probe)

public enum HADiscovery {
    private static let logger = Logger(subsystem: "com.yangzhiyuan.MenuBarMijia", category: "HADiscovery")

    /// Unescapes DNS-SD zone file escaping (e.g. `\032` for space or `\230\136\145` for UTF-8 bytes).
    public static func unescapeDNSSD(_ raw: String) -> String {
        var bytes: [UInt8] = []
        let chars = Array(raw.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                if i + 3 < chars.count,
                   let d1 = Self.decimalDigit(chars[i + 1]),
                   let d2 = Self.decimalDigit(chars[i + 2]),
                   let d3 = Self.decimalDigit(chars[i + 3]) {
                    let val = d1 * 100 + d2 * 10 + d3
                    if val <= 255 {
                        bytes.append(UInt8(val))
                        i += 4
                        continue
                    }
                }
                let nextScalar = chars[i + 1]
                for b in String(nextScalar).utf8 {
                    bytes.append(b)
                }
                i += 2
            } else {
                for b in String(c).utf8 {
                    bytes.append(b)
                }
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decimalDigit(_ scalar: UnicodeScalar) -> Int? {
        guard scalar.value >= 48 && scalar.value <= 57 else { return nil }
        return Int(scalar.value - 48)
    }

    /// Parses quoted `"key=value"` pairs from a DNS-SD TXT line.
    public static func parseTXTRecordTokens(_ rawTXTPart: String) -> [String: String] {
        var result: [String: String] = [:]
        var inQuotes = false
        var current = ""
        let scalars = Array(rawTXTPart.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let ch = scalars[i]
            if ch == "\\" && i + 1 < scalars.count {
                current.unicodeScalars.append(ch)
                current.unicodeScalars.append(scalars[i + 1])
                i += 2
                continue
            }
            if ch == "\"" {
                if inQuotes {
                    let unescaped = unescapeDNSSD(current)
                    if let eqIdx = unescaped.firstIndex(of: "=") {
                        let key = String(unescaped[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let val = String(unescaped[unescaped.index(after: eqIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !key.isEmpty {
                            result[key] = val
                        }
                    }
                    current = ""
                    inQuotes = false
                } else {
                    inQuotes = true
                    current = ""
                }
            } else if inQuotes {
                current.unicodeScalars.append(ch)
            }
            i += 1
        }
        return result
    }

    /// Builds a discovered instance from mDNS TXT and SRV fields.
    public static func buildInstance(
        instanceName: String?,
        txt: [String: String],
        srvPort: Int = 8123,
        srvTarget: String? = nil,
        source: String = "mDNS",
        hostResolver: (String) -> String? = resolveHostIPv4
    ) -> HADiscoveredInstance? {
        let port = srvPort > 0 ? srvPort : 8123
        let cleanTarget = srvTarget?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        let internalURL = Self.validHTTPURL(txt["internal_url"])
        let baseURL = Self.validHTTPURL(txt["base_url"])
        let externalURL = Self.validHTTPURL(txt["external_url"])

        let chosenURL: String?
        if let internalURL, Self.urlHasIPv4Host(internalURL) {
            chosenURL = internalURL
        } else if let baseURL, Self.urlHasIPv4Host(baseURL) {
            chosenURL = baseURL
        } else if let cleanTarget, !cleanTarget.isEmpty, let resolvedTargetIP = hostResolver(cleanTarget), !resolvedTargetIP.isEmpty {
            chosenURL = "http://\(resolvedTargetIP):\(port)"
        } else if let internalURL {
            chosenURL = internalURL
        } else if let baseURL {
            chosenURL = baseURL
        } else if let cleanTarget, !cleanTarget.isEmpty {
            chosenURL = "http://\(cleanTarget):\(port)"
        } else if let externalURL {
            chosenURL = externalURL
        } else {
            chosenURL = nil
        }

        guard let finalURL = chosenURL else { return nil }

        let locName: String
        if let txtName = txt["location_name"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !txtName.isEmpty {
            locName = txtName
        } else if let instanceName = instanceName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !instanceName.isEmpty {
            locName = instanceName
        } else {
            locName = "Home Assistant"
        }

        return HADiscoveredInstance(
            baseURL: finalURL,
            locationName: locName,
            version: txt["version"],
            uuid: txt["uuid"],
            source: source
        )
    }

    /// Parses the zone output of `dns-sd -Z _home-assistant._tcp local.`.
    public static func parseMDNSZoneOutput(
        _ output: String,
        hostResolver: (String) -> String? = resolveHostIPv4
    ) -> [HADiscoveredInstance] {
        struct PartialRecord {
            var instanceName: String
            var srvPort: Int = 8123
            var srvTarget: String?
            var txt: [String: String] = [:]
            var hasSRVOrTXT: Bool = false
        }

        var order: [String] = []
        var byInstance: [String: PartialRecord] = [:]
        let marker = "._home-assistant._tcp"

        for rawLine in output.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix(";") { continue }

            guard let markerRange = rawLine.range(of: marker) else { continue }
            let prefixRaw = String(rawLine[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let afterMarker = String(rawLine[markerRange.upperBound...])

            // Ignore PTR header lines where prefix starts with _home-assistant._tcp
            if prefixRaw.hasPrefix("_home-assistant._tcp") { continue }

            let instanceName = unescapeDNSSD(prefixRaw)
            if byInstance[instanceName] == nil {
                order.append(instanceName)
                byInstance[instanceName] = PartialRecord(instanceName: instanceName)
            }

            let uncommentedAfter: String = if let semiIdx = afterMarker.firstIndex(of: ";"),
                                              !afterMarker.contains("\"") {
                String(afterMarker[..<semiIdx])
            } else {
                afterMarker
            }

            let tokens = uncommentedAfter
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)

            if let srvIdx = tokens.firstIndex(of: "SRV"), srvIdx + 4 < tokens.count {
                if let port = Int(tokens[srvIdx + 3]) {
                    byInstance[instanceName]?.srvPort = port
                }
                byInstance[instanceName]?.srvTarget = tokens[srvIdx + 4]
                byInstance[instanceName]?.hasSRVOrTXT = true
            } else if let txtRange = afterMarker.range(of: "TXT") {
                let txtPayload = String(afterMarker[txtRange.upperBound...])
                let parsedTXT = parseTXTRecordTokens(txtPayload)
                for (k, v) in parsedTXT {
                    byInstance[instanceName]?.txt[k] = v
                }
                byInstance[instanceName]?.hasSRVOrTXT = true
            }
        }

        var results: [HADiscoveredInstance] = []
        var seenURLs: Set<String> = []

        for key in order {
            guard let rec = byInstance[key], rec.hasSRVOrTXT else { continue }
            if let inst = buildInstance(
                instanceName: rec.instanceName,
                txt: rec.txt,
                srvPort: rec.srvPort,
                srvTarget: rec.srvTarget,
                source: "mDNS",
                hostResolver: hostResolver
            ) {
                if seenURLs.insert(inst.baseURL).inserted {
                    results.append(inst)
                }
            }
        }
        return results
    }

    /// Parses private LAN IPv4 addresses from `arp -an` or `arp -a` output.
    public static func parseARPTableHosts(_ arpOutput: String) -> [String] {
        var hosts: [String] = []
        var seen: Set<String> = []

        for line in arpOutput.components(separatedBy: .newlines) {
            guard let openParen = line.firstIndex(of: "("),
                  let closeParen = line[openParen...].firstIndex(of: ")") else {
                continue
            }
            let ip = String(line[line.index(after: openParen)..<closeParen])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPrivateLANIPv4(ip) else { continue }
            if seen.insert(ip).inserted {
                hosts.append(ip)
            }
        }
        return hosts
    }

    /// Checks whether HTTP response data from `/manifest.json` belongs to Home Assistant.
    public static func isHomeAssistantManifest(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = obj["name"] as? String, name.localizedCaseInsensitiveContains("Home Assistant") {
                return true
            }
            if let shortName = obj["short_name"] as? String, shortName.localizedCaseInsensitiveContains("Home Assistant") {
                return true
            }
        }
        if let text = String(data: data, encoding: .utf8),
           text.contains("io.homeassistant") || text.contains("\"Home Assistant\"") {
            return true
        }
        return false
    }

    /// Merges mDNS and HTTP-probed instances, keeping rich mDNS metadata when URLs match.
    public static func mergeInstances(
        mdns: [HADiscoveredInstance],
        probed: [HADiscoveredInstance]
    ) -> [HADiscoveredInstance] {
        var merged: [HADiscoveredInstance] = []
        var indexByURL: [String: Int] = [:]

        for item in mdns {
            if indexByURL[item.baseURL] == nil {
                indexByURL[item.baseURL] = merged.count
                merged.append(item)
            }
        }
        for item in probed {
            if indexByURL[item.baseURL] == nil {
                indexByURL[item.baseURL] = merged.count
                merged.append(item)
            }
        }
        return merged
    }

    // MARK: - Live LAN Discovery Entry Point

    public static func discoverOnLAN(currentURLHint: String? = nil) async -> [HADiscoveredInstance] {
        async let mdnsTask: [HADiscoveredInstance] = Task.detached(priority: .userInitiated) {
            Self.queryMDNSInstances()
        }.value

        var initialCandidates: [String] = []
        var seenCandidates: Set<String> = []

        func addCandidate(_ raw: String, into list: inout [String]) {
            let norm = HAWebSocketProvider.normalizeBaseURL(raw)
            guard !norm.isEmpty, seenCandidates.insert(norm).inserted else { return }
            list.append(norm)
        }

        if let hint = currentURLHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            addCandidate(hint, into: &initialCandidates)
        }
        addCandidate(KeychainHelper.defaultNASURL, into: &initialCandidates)

        let arpHosts = await Task.detached(priority: .utility) {
            Self.queryARPHosts()
        }.value
        for ip in arpHosts {
            addCandidate("http://\(ip):8123", into: &initialCandidates)
        }

        async let initialProbeTask = probeCandidateURLs(initialCandidates)

        let mdnsFound = await mdnsTask
        var probed = await initialProbeTask

        var extraMDNSCandidates: [String] = []
        for inst in mdnsFound {
            addCandidate(inst.baseURL, into: &extraMDNSCandidates)
        }
        if !extraMDNSCandidates.isEmpty {
            let extraProbed = await probeCandidateURLs(extraMDNSCandidates)
            probed.append(contentsOf: extraProbed)
        }

        let merged = mergeInstances(mdns: mdnsFound, probed: probed)

        // Prefer instances confirmed reachable by HTTP probe first, followed by remaining mDNS results
        let reachableSet = Set(probed.map(\.baseURL))
        let sorted = merged.sorted { a, b in
            let aReachable = reachableSet.contains(a.baseURL)
            let bReachable = reachableSet.contains(b.baseURL)
            if aReachable != bReachable { return aReachable }
            let aIsIP = urlHasIPv4Host(a.baseURL)
            let bIsIP = urlHasIPv4Host(b.baseURL)
            if aIsIP != bIsIP { return aIsIP }
            return false
        }

        if let first = sorted.first {
            logger.info("Discovered Home Assistant on LAN: \(first.displaySummary, privacy: .public)")
        }
        return sorted
    }

    // MARK: - Platform Helpers

    public static func resolveHostIPv4(_ host: String) -> String? {
        let clean = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !clean.isEmpty else { return nil }
        if isPrivateLANIPv4(clean) { return clean }

        #if canImport(Darwin)
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(clean, nil, &hints, &res)
        guard status == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }

        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let info = ptr {
            if info.pointee.ai_family == AF_INET, let addrPtr = info.pointee.ai_addr {
                let sinPtr = UnsafeRawPointer(addrPtr).assumingMemoryBound(to: sockaddr_in.self)
                var addr = sinPtr.pointee.sin_addr
                var buffer = [UInt8](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                        return ip
                    }
                }
            }
            ptr = info.pointee.ai_next
        }
        #endif
        return nil
    }

    private static func queryMDNSInstances() -> [HADiscoveredInstance] {
        #if canImport(Darwin)
        guard let output = runCommand(
            executable: "/usr/bin/dns-sd",
            arguments: ["-t", "1", "-Z", "_home-assistant._tcp", "local."]
        ) else {
            return []
        }
        return parseMDNSZoneOutput(output)
        #else
        return []
        #endif
    }

    static func queryARPHosts() -> [String] {
        #if canImport(Darwin)
        guard let output = runCommand(
            executable: "/usr/sbin/arp",
            arguments: ["-an"]
        ) else {
            return []
        }
        return parseARPTableHosts(output)
        #else
        return []
        #endif
    }

    #if canImport(Darwin)
    private static func runCommand(executable: String, arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }
    #endif

    private static func probeCandidateURLs(_ urls: [String]) async -> [HADiscoveredInstance] {
        guard !urls.isEmpty else { return [] }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 0.75
        config.timeoutIntervalForResource = 0.9
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        return await withTaskGroup(of: (Int, HADiscoveredInstance?).self) { group in
            for (idx, baseURL) in urls.enumerated() {
                group.addTask {
                    guard let url = URL(string: "\(baseURL)/manifest.json") else {
                        return (idx, nil)
                    }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 0.75
                    do {
                        let (data, resp) = try await session.data(for: req)
                        if let http = resp as? HTTPURLResponse,
                           (200...299).contains(http.statusCode),
                           Self.isHomeAssistantManifest(data) {
                            return (
                                idx,
                                HADiscoveredInstance(
                                    baseURL: baseURL,
                                    locationName: "Home Assistant",
                                    source: "HTTP"
                                )
                            )
                        }
                    } catch {}
                    return (idx, nil)
                }
            }

            var indexed: [(Int, HADiscoveredInstance)] = []
            for await (idx, found) in group {
                if let found {
                    indexed.append((idx, found))
                }
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func validHTTPURL(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"),
              let url = URL(string: trimmed),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return HAWebSocketProvider.normalizeBaseURL(trimmed)
    }

    private static func urlHasIPv4Host(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host else { return false }
        return isPrivateLANIPv4(host)
    }

    public static func isPrivateLANIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == 4, nums.allSatisfy({ (0...255).contains($0) }) else { return false }
        // Exclude network/broadcast endpoints
        guard nums[3] != 0 && nums[3] != 255 else { return false }
        if nums[0] == 10 { return true }
        if nums[0] == 192 && nums[1] == 168 { return true }
        if nums[0] == 172 && (16...31).contains(nums[1]) { return true }
        return false
    }
}
