import CryptoKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import os

public protocol XiaomiCameraBridging: Sendable {
    func startBridge(
        did: String,
        model: String,
        localIP: String,
        clientPublic: String,
        clientPrivate: String,
        devicePublic: String,
        sign: String,
        vendor: String,
        uid: String?
    ) async throws -> XiaomiCameraStreamEndpoints

    func stopBridge(did: String) async
}

/// Local go2rtc URLs for one bridged camera (#97).
public struct XiaomiCameraStreamEndpoints: Equatable, Sendable {
    /// Untranscoded H.264/H.265 as progressive fragmented MP4, decoded natively by the app.
    public var mp4: URL
    /// FFmpeg-transcoded MJPEG, kept as a fallback when native decoding fails.
    public var mjpeg: URL

    public init(mp4: URL, mjpeg: URL) {
        self.mp4 = mp4
        self.mjpeg = mjpeg
    }
}

/// Manages the local CS2 UDP LAN relay and `go2rtc` transcode daemon for Xiaomi P2P cameras (#97).
public actor XiaomiCameraBridge: XiaomiCameraBridging {
    public static let shared = XiaomiCameraBridge()

    private let logger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "XiaomiCameraBridge")
    private var relays: [String: RelayHandle] = [:]
    private var go2rtcProcess: Process?

    private struct RelayHandle {
        let port: UInt16
        let stopBox: RelayStopBox
    }

    public init() {}

    public static func makeX25519KeyPair() -> (publicKeyHex: String, privateKeyHex: String) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let pubHex = privateKey.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let privHex = privateKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return (pubHex, privHex)
    }

    public func startBridge(
        did: String,
        model: String,
        localIP: String,
        clientPublic: String,
        clientPrivate: String,
        devicePublic: String,
        sign: String,
        vendor: String,
        uid: String?
    ) async throws -> XiaomiCameraStreamEndpoints {
        let trimmedIP = localIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ipv4 = Self.parsePrivateOrLoopbackIPv4(trimmedIP) else {
            throw HomeProviderError.serviceCallFailed(400, L10n.tr("无效或非局域网摄像机 IP：\(trimmedIP)", "Invalid or non-LAN camera IP: \(trimmedIP)"))
        }

        try await ensureGo2RTCRunning()

        let cleanDid = Self.sanitizeDid(did)
        let rawName = "cam_raw_\(cleanDid)"
        let h264Name = "cam_h264_\(cleanDid)"
        let mjpegName = "cam_mjpeg_\(cleanDid)"

        let session = Self.makeLocalHTTPClient()
        defer { session.invalidateAndCancel() }

        // h264Name is no longer registered but is still deleted, so streams left by older builds go away.
        await stopBridgeInternal(session: session, cleanDid: cleanDid, names: [rawName, h264Name, mjpegName])

        let relayPort = try ensureRelayPort(cleanDid: cleanDid, camIP: ipv4)

        var query = [
            "client_public=\(Self.urlEncode(clientPublic))",
            "client_private=\(Self.urlEncode(clientPrivate))",
            "device_public=\(Self.urlEncode(devicePublic))",
            "sign=\(Self.urlEncode(sign))",
            "vendor=\(Self.urlEncode(vendor))",
            "transport=udp",
            "subtype=sd",
            "audio=0",
            "model=\(Self.urlEncode(model))",
        ].joined(separator: "&")

        if let uid, !uid.isEmpty {
            query += "&uid=\(Self.urlEncode(uid))"
        }
        let xiaomiURL = "xiaomi://127.0.0.1:\(relayPort)?\(query)"

        try await putStream(session: session, name: rawName, src: xiaomiURL)
        try await putStream(session: session, name: mjpegName, src: "ffmpeg:\(rawName)#video=mjpeg")

        // `mp4` (empty) selects go2rtc's H.264 + H.265 fMP4 profile, so the camera's own
        // bitstream reaches VideoToolbox without an FFmpeg transcode in between.
        guard let mp4URL = URL(string: "http://127.0.0.1:1984/api/stream.mp4?src=\(Self.urlEncode(rawName))&mp4"),
              let mjpegURL = URL(string: "http://127.0.0.1:1984/api/stream.mjpeg?src=\(Self.urlEncode(mjpegName))") else {
            throw HomeProviderError.serviceCallFailed(500, "Invalid go2rtc stream URL")
        }
        return XiaomiCameraStreamEndpoints(mp4: mp4URL, mjpeg: mjpegURL)
    }

    public func stopBridge(did: String) async {
        let cleanDid = Self.sanitizeDid(did)
        let rawName = "cam_raw_\(cleanDid)"
        let h264Name = "cam_h264_\(cleanDid)"
        let mjpegName = "cam_mjpeg_\(cleanDid)"
        let session = Self.makeLocalHTTPClient(timeout: 3.0)
        defer { session.invalidateAndCancel() }
        await stopBridgeInternal(session: session, cleanDid: cleanDid, names: [rawName, h264Name, mjpegName])
    }

    private func stopBridgeInternal(session: URLSession, cleanDid: String, names: [String]) async {
        for name in names {
            if let url = URL(string: "http://127.0.0.1:1984/api/streams?src=\(Self.urlEncode(name))") {
                var req = URLRequest(url: url)
                req.httpMethod = "DELETE"
                _ = try? await session.data(for: req)
            }
        }
        if let existing = relays.removeValue(forKey: cleanDid) {
            existing.stopBox.stop()
        }
    }

    private func putStream(session: URLSession, name: String, src: String) async throws {
        let urlString = "http://127.0.0.1:1984/api/streams?name=\(Self.urlEncode(name))&src=\(Self.urlEncode(src))"
        guard let url = URL(string: urlString) else {
            throw HomeProviderError.serviceCallFailed(500, "Invalid go2rtc stream URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw HomeProviderError.serviceCallFailed(code, L10n.tr("注册摄像机流失败 (HTTP \(code))", "Failed to register camera stream (HTTP \(code))"))
        }
    }

    private func ensureRelayPort(cleanDid: String, camIP: in_addr) throws -> UInt16 {
        if let existing = relays[cleanDid], !existing.stopBox.isStopped {
            return existing.port
        }
        relays.removeValue(forKey: cleanDid)
        let (port, stopBox) = try Self.spawnCS2UDPRelay(camIP: camIP)
        relays[cleanDid] = RelayHandle(port: port, stopBox: stopBox)
        return port
    }

    private func ensureGo2RTCRunning() async throws {
        guard let exePath = Self.locateGo2RTCBinary() else {
            throw HomeProviderError.serviceCallFailed(
                501,
                L10n.tr(
                    "未找到本地流媒体组件 go2rtc（可放入 ~/Library/Application Support/MenuBarMijia/bin/go2rtc）",
                    "Local streaming helper go2rtc not found"
                )
            )
        }

        let appSupportBin = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuBarMijia/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupportBin, withIntermediateDirectories: true)

        let ffmpegBin = Self.locateFFmpegBinary()
        // `webrtc: listen: ""` keeps go2rtc from opening port 8555 on every LAN interface;
        // the app only talks to it over loopback.
        let desiredConfig = """
        api:
          listen: 127.0.0.1:1984
          origin: "*"
        rtsp:
          listen: 127.0.0.1:8554
        webrtc:
          listen: ""
        log:
          level: info
          ffmpeg: error
        ffmpeg:
          bin: \(ffmpegBin)
        """
        let cfgURL = appSupportBin.appendingPathComponent("go2rtc.yaml")
        let existingConfig = (try? String(contentsOf: cfgURL, encoding: .utf8)) ?? ""
        // go2rtc appends every API-registered stream to its config file, so only the part
        // this app writes is compared; otherwise every open looked like a config change and
        // restarted (or duplicated) the daemon.
        let configChanged = Self.baseConfig(existingConfig) != Self.baseConfig(desiredConfig)
        if configChanged {
            try desiredConfig.write(to: cfgURL, atomically: true, encoding: .utf8)
        }

        let probeSession = Self.makeLocalHTTPClient(timeout: 0.8)
        defer { probeSession.invalidateAndCancel() }
        let apiURL = URL(string: "http://127.0.0.1:1984/api")!
        func probe() async -> Bool {
            guard let (_, resp) = try? await probeSession.data(from: apiURL),
                  let http = resp as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        }

        let isRunning = await probe()
        if isRunning && !configChanged {
            return
        }
        if isRunning {
            if let proc = go2rtcProcess, proc.isRunning {
                proc.terminate()
            } else if let exitURL = URL(string: "http://127.0.0.1:1984/api/exit") {
                // A daemon left by an earlier app launch: ask it to quit instead of starting a
                // second copy that cannot bind the API port.
                var req = URLRequest(url: exitURL)
                req.httpMethod = "POST"
                _ = try? await probeSession.data(for: req)
            }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if await !probe() { break }
            }
        }

        let logURL = appSupportBin.appendingPathComponent("go2rtc.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exePath)
        proc.arguments = ["-c", cfgURL.path]
        proc.currentDirectoryURL = appSupportBin
        proc.standardOutput = logHandle ?? FileHandle.nullDevice
        proc.standardError = logHandle ?? FileHandle.nullDevice
        try proc.run()
        go2rtcProcess = proc

        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(120))
            if await probe() {
                return
            }
        }
        throw HomeProviderError.serviceCallFailed(504, L10n.tr("本地流媒体服务 (127.0.0.1:1984) 启动超时", "Local streaming service (127.0.0.1:1984) timed out starting"))
    }

    /// The app-owned part of go2rtc.yaml, without the `streams:` section go2rtc appends.
    static func baseConfig(_ yaml: String) -> String {
        var kept: [Substring] = []
        var inStreams = false
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let isTopLevel = !(line.first?.isWhitespace ?? true)
            if isTopLevel {
                inStreams = line.hasPrefix("streams:")
            }
            if !inStreams {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func locateGo2RTCBinary() -> String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("bin/go2rtc").path)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuBarMijia/bin/go2rtc").path
        candidates.append(contentsOf: [
            appSupport,
            "/opt/homebrew/bin/go2rtc",
            "/usr/local/bin/go2rtc",
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func locateFFmpegBinary() -> String {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("bin/ffmpeg").path)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuBarMijia/bin/ffmpeg").path
        candidates.append(contentsOf: [
            appSupport,
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ffmpeg"
    }

    private static func makeLocalHTTPClient(timeout: TimeInterval = 6.0) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }

    static func sanitizeDid(_ did: String) -> String {
        String(did.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" })
    }

    static func urlEncode(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    static func parsePrivateOrLoopbackIPv4(_ raw: String) -> in_addr? {
        var addr = in_addr()
        guard inet_pton(AF_INET, raw, &addr) == 1 else { return nil }
        let hostOrder = UInt32(bigEndian: addr.s_addr)
        let a = UInt8((hostOrder >> 24) & 0xFF)
        let b = UInt8((hostOrder >> 16) & 0xFF)
        let isPrivate =
            a == 10 ||
            (a == 172 && (16...31).contains(b)) ||
            (a == 192 && b == 168) ||
            a == 127
        return isPrivate ? addr : nil
    }

    // MARK: - CS2 UDP LAN Relay

    private static func spawnCS2UDPRelay(camIP: in_addr) throws -> (UInt16, RelayStopBox) {
        #if canImport(Darwin)
        let probeFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard probeFD >= 0 else {
            throw HomeProviderError.networkError("UDP probe socket failed")
        }
        var camTarget = sockaddr_in()
        camTarget.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        camTarget.sin_family = sa_family_t(AF_INET)
        camTarget.sin_port = UInt16(32108).bigEndian
        camTarget.sin_addr = camIP
        let connectRes = withUnsafePointer(to: &camTarget) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probeFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectRes == 0 else {
            Darwin.close(probeFD)
            throw HomeProviderError.networkError("UDP route discovery failed")
        }
        var localRouteAddr = sockaddr_in()
        var localRouteLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &localRouteAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(probeFD, $0, &localRouteLen)
            }
        }
        let localInterfaceIP = localRouteAddr.sin_addr
        Darwin.close(probeFD)

        let hostOrderCam = UInt32(bigEndian: camIP.s_addr)
        let broadcastAddr = in_addr(s_addr: (hostOrderCam | 0x0000_00FF).bigEndian)

        let localRelayFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard localRelayFD >= 0 else {
            throw HomeProviderError.networkError("Local relay socket failed")
        }
        var loopbackBind = sockaddr_in()
        loopbackBind.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        loopbackBind.sin_family = sa_family_t(AF_INET)
        loopbackBind.sin_port = 0
        loopbackBind.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bindLocalRes = withUnsafePointer(to: &loopbackBind) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(localRelayFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindLocalRes == 0 else {
            Darwin.close(localRelayFD)
            throw HomeProviderError.networkError("Local relay bind failed")
        }
        var boundRelayAddr = sockaddr_in()
        var boundRelayLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundRelayAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(localRelayFD, $0, &boundRelayLen)
            }
        }
        let relayPort = UInt16(bigEndian: boundRelayAddr.sin_port)

        let lanFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard lanFD >= 0 else {
            Darwin.close(localRelayFD)
            throw HomeProviderError.networkError("LAN relay socket failed")
        }
        var broadcastOn: Int32 = 1
        _ = setsockopt(lanFD, SOL_SOCKET, SO_BROADCAST, &broadcastOn, socklen_t(MemoryLayout<Int32>.size))

        var lanBind = sockaddr_in()
        lanBind.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        lanBind.sin_family = sa_family_t(AF_INET)
        lanBind.sin_port = 0
        lanBind.sin_addr = localInterfaceIP
        let bindLanRes = withUnsafePointer(to: &lanBind) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(lanFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindLanRes == 0 else {
            Darwin.close(localRelayFD)
            Darwin.close(lanFD)
            throw HomeProviderError.networkError("LAN relay bind failed")
        }

        // CS2 over UDP acknowledges every DRW video packet, and the camera stalls its send
        // window until those ACKs arrive. The relay therefore multiplexes both directions
        // with poll(2) and drains each socket without blocking: the old loop forwarded at
        // most one go2rtc→camera packet per 25 ms idle gap on the LAN side, so ACKs piled
        // up during every keyframe burst and the picture advanced a frame at a time.
        for fd in [localRelayFD, lanFD] {
            var bufferBytes: Int32 = 4 * 1024 * 1024
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferBytes, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferBytes, socklen_t(MemoryLayout<Int32>.size))
            let fl = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        }

        let stopBox = RelayStopBox()
        let thread = Thread {
            defer {
                Darwin.close(localRelayFD)
                Darwin.close(lanFD)
            }
            var go2rtcAddr: sockaddr_in?
            var camDynamicPort: UInt16 = 32108
            var commandGate = CS2CommandChannelGate()
            var droppedCommands = 0
            let relayLogger = Logger(subsystem: "com.jryang1997.MenuBarMijia", category: "XiaomiCameraBridge")
            var buf = [UInt8](repeating: 0, count: 65_536)
            var fds = [
                pollfd(fd: localRelayFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: lanFD, events: Int16(POLLIN), revents: 0),
            ]

            while !stopBox.isStopped {
                fds[0].revents = 0
                fds[1].revents = 0
                // The timeout only bounds how quickly a stop request is noticed.
                let ready = poll(&fds, nfds_t(fds.count), 200)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 { continue }

                // go2rtc → camera (handshake, commands, DRW ACKs).
                if fds[0].revents & Int16(POLLIN) != 0 {
                    while true {
                        var srcAddr = sockaddr_in()
                        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                        let n = buf.withUnsafeMutableBytes { rawBuf in
                            withUnsafeMutablePointer(to: &srcAddr) { srcPtr in
                                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                                    recvfrom(localRelayFD, rawBuf.baseAddress, rawBuf.count, 0, saPtr, &srcLen)
                                }
                            }
                        }
                        if n <= 0 { break }
                        go2rtcAddr = srcAddr
                        if n >= 2 && buf[0] == 0xF1 && buf[1] == 0x30 {
                            commandGate.reset() // LAN_SEARCH starts a fresh CS2 session
                            droppedCommands = 0
                            Self.sendUDP(fd: lanFD, bytes: buf, count: n, ip: broadcastAddr, port: 32108)
                            Self.sendUDP(fd: lanFD, bytes: buf, count: n, ip: camIP, port: 32108)
                        } else {
                            Self.sendUDP(fd: lanFD, bytes: buf, count: n, ip: camIP, port: camDynamicPort)
                        }
                    }
                }

                // camera → go2rtc (video DRW packets, pings, command replies).
                if fds[1].revents & Int16(POLLIN) != 0 {
                    while true {
                        var lanSrc = sockaddr_in()
                        var lanLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                        let m = buf.withUnsafeMutableBytes { rawBuf in
                            withUnsafeMutablePointer(to: &lanSrc) { srcPtr in
                                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                                    recvfrom(lanFD, rawBuf.baseAddress, rawBuf.count, 0, saPtr, &lanLen)
                                }
                            }
                        }
                        if m <= 0 { break }
                        guard lanSrc.sin_addr.s_addr == camIP.s_addr else { continue }
                        camDynamicPort = UInt16(bigEndian: lanSrc.sin_port)
                        if commandGate.shouldDrop(buf, count: m) {
                            // Acknowledge on go2rtc's behalf so the camera stops retransmitting.
                            let ack: [UInt8] = [0xF1, 0xD1, 0x00, 0x06, 0xD1, 0x00, 0x00, 0x01, buf[6], buf[7]]
                            Self.sendUDP(fd: lanFD, bytes: ack, count: ack.count, ip: camIP, port: camDynamicPort)
                            droppedCommands += 1
                            if droppedCommands == 1 || droppedCommands % 50 == 0 {
                                relayLogger.notice("CS2 relay acknowledged and dropped \(droppedCommands) unread command-channel messages")
                            }
                            continue
                        }
                        if var clientAddr = go2rtcAddr {
                            _ = buf.withUnsafeBytes { rawBuf in
                                withUnsafePointer(to: &clientAddr) { dstPtr in
                                    dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                                        sendto(localRelayFD, rawBuf.baseAddress, m, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        thread.name = "com.jryang1997.MenuBarMijia.cs2-udp-relay"
        thread.qualityOfService = .userInteractive
        thread.start()

        return (relayPort, stopBox)
        #else
        throw HomeProviderError.networkError("CS2 UDP relay requires Darwin")
        #endif
    }

    #if canImport(Darwin)
    private static func sendUDP(fd: Int32, bytes: [UInt8], count: Int, ip: in_addr, port: UInt16) {
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = port.bigEndian
        dst.sin_addr = ip
        _ = bytes.withUnsafeBytes { rawBuf in
            withUnsafePointer(to: &dst) { dstPtr in
                dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(fd, rawBuf.baseAddress, count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    #endif
}

/// Keeps go2rtc's CS2 command channel from overflowing (#97).
///
/// go2rtc reads exactly one channel-0 message (the login reply) and never reads that channel
/// again, but the camera keeps sending status messages there (about one every 2.3 s). Its
/// 10-slot buffer fills after ~23 s and go2rtc drops the whole P2P session ("cs2: pop buffer
/// is full"), which froze the picture for several seconds on a fixed cycle. The relay lets the
/// first few command messages of each session through and acknowledges and drops the rest.
struct CS2CommandChannelGate {
    static let passthroughLimit = 6
    private var forwardedSequences: Set<UInt16> = []

    mutating func reset() {
        forwardedSequences.removeAll()
    }

    /// True for a camera→client DRW packet on channel 0 beyond the passthrough allowance.
    /// Retransmissions of an already forwarded message keep passing so go2rtc can re-ACK them.
    mutating func shouldDrop(_ packet: [UInt8], count: Int) -> Bool {
        guard count >= 8, packet[0] == 0xF1, packet[1] == 0xD0, packet[4] == 0xD1, packet[5] == 0 else {
            return false
        }
        let seq = UInt16(packet[6]) << 8 | UInt16(packet[7])
        if forwardedSequences.contains(seq) { return false }
        if forwardedSequences.count < Self.passthroughLimit {
            forwardedSequences.insert(seq)
            return false
        }
        return true
    }
}

final class RelayStopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
